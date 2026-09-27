(*
 * Trndi
 * Medical and Non-Medical Usage Alert
 *
 * Copyright (c) Björn Lindh
 * GitHub: https://github.com/slicke/trndi
 *
 * This program is distributed under the terms of the GNU General Public License,
 * Version 3, as published by the Free Software Foundation. You may redistribute
 * and/or modify the software under the terms of this license.
 *
 * A copy of the GNU General Public License should have been provided with this
 * program. If not, see <http://www.gnu.org/licenses/gpl.html>.
 *
 * ================================== IMPORTANT ==================================
 * MEDICAL DISCLAIMER:
 * - This software is NOT a medical device and must NOT replace official continuous
 *   glucose monitoring (CGM) systems or any healthcare decision-making process.
 * - The data provided may be delayed, inaccurate, or unavailable.
 * - DO NOT make medical decisions based on this software.
 * - VERIFY all data using official devices and consult a healthcare professional for
 *   medical concerns or emergencies.
 *
 * LIABILITY LIMITATION:
 * - The software is provided "AS IS" and without any warranty—expressed or implied.
 * - Users assume all risks associated with its use. The developers disclaim all
 *   liability for any damage, injury, or harm, direct or incidental, arising
 *   from its use.
 *
 * INSTRUCTIONS TO DEVELOPERS & USERS:
 * - Any modifications to this file must include a prominent notice outlining what was
 *   changed and the date of modification (as per GNU GPL Section 5).
 * - Distribution of a modified version must include this header and comply with the
 *   license terms.
 *
 * BY USING THIS SOFTWARE, YOU AGREE TO THE TERMS AND DISCLAIMERS STATED HERE.
 *
 *)
{**
  Menu-bar status items for trndi-multi: @link(TMultiStatusNative) adds them
  to Trndi's native by inheritance, so the vendored Trndi is used as is.

  Trndi's own menu-bar reading (develop, after build-249) holds one item per
  process, which cannot carry one reading per account. This is the same
  pill -- the reading in the window's colours, typeset like the menu bar
  clock -- kept per key, with an optional lead label (the account's name)
  before the value. The contract follows Trndi's (SetStatusItemMenu,
  ShowStatusItem, HideStatusItem, StatusItemDefault) with a key added, so
  it can move upstream later.

  macOS only; elsewhere @code(SupportsStatusItem) is false and the rest are
  no-ops.
}
unit trndimulti.statusitem;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$ENDIF}

interface

uses
Classes, SysUtils, Graphics, trndi.native.base, trndimulti.accounts;

type
  {** Trndi's native (via @link(TMultiNative)) with keyed status items. }
  TMultiStatusNative = class(TMultiNative)
  public
    {** True where there is a menu bar to put items in (macOS). }
    class function SupportsStatusItem: boolean;
    {** Default while the user has not chosen: on when the Dock hides
        itself, as Trndi's own menu-bar reading defaults. }
    class function StatusItemDefault: boolean;
    {** Captions and click targets for the menu of the item for
        @param(key). The callbacks fire on the main thread. Call before
        @link(ShowStatusItem); later calls relabel the menu. }
    procedure SetStatusItemMenu(const key: string;
      const showCaption, hideCaption, quitCaption: string;
      const onShow, onHide, onQuit: TTrndiWakeCallback);
    {** Show or refresh the item for @param(key): @param(Lead) and
        @param(Detail) faded either side of the semibold @param(Value), on a
        pill painted @param(bg)/@param(textColor). An empty @param(Value)
        hides the item. AppKit places a new item to the left of those
        already shown. @returns(@true when the item is shown.) }
    function ShowStatusItem(const key, Lead, Value, Detail: string;
      bg, textColor: TColor): boolean;
    {** Take the item for @param(key) out of the menu bar, if shown. }
    procedure HideStatusItem(const key: string);
  end;

implementation

{$IFDEF DARWIN}
uses
CocoaAll, CGBase, trndi.native.wakebridge;

{------------------------------------------------------------------------------
  One entry per key -- item, text, colour, menu and menu target -- kept for
  the life of the process once created, so the image reps and menus that
  point at it never outlive it; HideStatusItem only takes the NSStatusItem
  away.

  The pill is drawn into an NSImage rather than set as an attributed title: a
  status-bar button draws its own background, so a coloured background
  attribute comes out as a hard rectangle that ignores the bar's height. The
  image carries an NSCustomImageRep instead of a bitmap, so AppKit asks for
  the drawing at whatever backing scale the menu bar is on -- sharp on
  Retina and non-Retina alike. It is not a template, so it keeps the range
  colour in light and dark menu bars.

  Menu entries are marshalled to the main thread through TTrndiWakeBridge:
  "Quit" closes the main form, and doing that from inside AppKit's menu
  tracking loop invites a wedged event loop.
 ------------------------------------------------------------------------------}
const
  ObjCLib = '/usr/lib/libobjc.A.dylib';
  SITEM_H_PAD    = 6;     // pt of breathing room left/right of the text
  SITEM_V_INSET  = 3;     // pt between the pill and the menu bar's edges
  SITEM_MIN_H    = 16;    // floor for the pill height
  SITEM_MAX_H    = 18;    // ceiling, so the tall notch-era bar gets no slab
  SITEM_RADIUS   = 5;     // pt; macOS control-style corners, not a capsule
  SITEM_FONT_SZ  = 13;    // the menu bar's own text size
  SITEM_FADED_ALPHA = 0.72; // lead, arrow and change, a step behind the value
  // NSFontWeight values (NSFontWeightSemibold / NSFontWeightRegular); the
  // exported constants are not in CocoaAll.
  SITEM_WEIGHT_VALUE  = 0.3;
  SITEM_WEIGHT_FADED  = 0.0;

type
  TStatusEntry = class;

  // Target for one entry's menu, and the delegate that draws its pill.
  TMultiStatusTarget = objcclass(NSObject)
  public
    entry: Pointer; // TStatusEntry; never freed, see above
    procedure showClicked(sender: id); message 'showClicked:';
    procedure hideClicked(sender: id); message 'hideClicked:';
    procedure quitClicked(sender: id); message 'quitClicked:';
    procedure drawPill(rep: NSCustomImageRep); message 'drawPill:';
  end;

  TStatusEntry = class
    key: string;
    item: NSStatusItem;       // nil while hidden; retained while shown
    target: TMultiStatusTarget;
    menu: NSMenu;
    showItem, hideItem, quitItem: NSMenuItem;
    showBridge, hideBridge, quitBridge: TTrndiWakeBridge;
    text: NSAttributedString; // What drawPill paints; retained
    bg: TColor;
  end;

var
  gEntries: TList = nil; // of TStatusEntry

// +[NSFont monospacedDigitSystemFontOfSize:weight:] (10.11+) takes two
// CGFloats; called through objc_msgSend with that shape.
function objc_msgSend_font(cls: id; sel: SEL; size, weight: CGFloat): id;
  cdecl; external ObjCLib name 'objc_msgSend';
function objc_msgSend_bool_sel(obj: id; sel: SEL; p1: SEL): ObjCBOOL;
  cdecl; external ObjCLib name 'objc_msgSend';
function sel_registerName(name: PChar): SEL; cdecl; external ObjCLib;

function Entry(const key: string; create: boolean): TStatusEntry;
var
  i: integer;
begin
  if gEntries = nil then
    gEntries := TList.Create;
  for i := 0 to gEntries.Count - 1 do
  begin
    Result := TStatusEntry(gEntries[i]);
    if Result.key = key then
      Exit;
  end;
  Result := nil;
  if not create then
    Exit;
  Result := TStatusEntry.Create;
  Result.key := key;
  Result.bg := clBlack;
  Result.target := TMultiStatusTarget.alloc.init;
  Result.target.entry := Result;
  gEntries.Add(Result);
end;

// TColor after ColorToRGB is $00BBGGRR.
function ToNSColor(c: TColor): NSColor;
var
  rgb: longint;
begin
  rgb := ColorToRGB(c);
  Result := NSColor.colorWithSRGBRed_green_blue_alpha((rgb and $FF) / 255.0,
    ((rgb shr 8) and $FF) / 255.0, ((rgb shr 16) and $FF) / 255.0, 1.0);
end;

// Menu-bar font at @param(weight), digits monospaced so the pill keeps its
// width as the value changes; plain system font where that is missing.
function PillFont(weight: CGFloat): NSFont;
var
  fontSel: SEL;
begin
  fontSel := sel_registerName('monospacedDigitSystemFontOfSize:weight:');
  if objc_msgSend_bool_sel(NSFont, sel_registerName('respondsToSelector:'), fontSel) then
    Result := NSFont(objc_msgSend_font(NSFont, fontSel, SITEM_FONT_SZ, weight))
  else if weight > 0 then
    Result := NSFont.boldSystemFontOfSize(SITEM_FONT_SZ)
  else
    Result := NSFont.systemFontOfSize(SITEM_FONT_SZ);
end;

function UTF8NS(const s: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PChar(s));
end;

// Autoreleased run of @param(text) in @param(font)/@param(color).
function Run(const text: string; font: NSFont; color: NSColor): NSAttributedString;
var
  attrs: NSMutableDictionary;
begin
  attrs := NSMutableDictionary.dictionaryWithCapacity(2);
  attrs.setObject_forKey(font, NSFontAttributeName);
  attrs.setObject_forKey(color, NSForegroundColorAttributeName);
  Result := NSAttributedString.alloc.initWithString_attributes(UTF8NS(text), attrs);
  Result.autorelease;
end;

procedure TMultiStatusTarget.showClicked(sender: id);
begin
  if Assigned(TStatusEntry(entry).showBridge) then
    TStatusEntry(entry).showBridge.Queue;
end;

procedure TMultiStatusTarget.hideClicked(sender: id);
begin
  if Assigned(TStatusEntry(entry).hideBridge) then
    TStatusEntry(entry).hideBridge.Queue;
end;

procedure TMultiStatusTarget.quitClicked(sender: id);
begin
  if Assigned(TStatusEntry(entry).quitBridge) then
    TStatusEntry(entry).quitBridge.Queue;
end;

procedure TMultiStatusTarget.drawPill(rep: NSCustomImageRep);
var
  e: TStatusEntry;
  sz: NSSize;
  pill: NSRect;
  path: NSBezierPath;
  font: NSFont;
begin
  e := TStatusEntry(entry);
  if e.text = nil then
    Exit;
  sz := rep.size;
  pill := NSMakeRect(0, 0, sz.width, sz.height);
  path := NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius(pill,
    SITEM_RADIUS, SITEM_RADIUS);
  ToNSColor(e.bg).setFill;
  path.fill;
  // Hairline edge a shade darker than the fill, inside the pill: keeps the
  // shape against a menu bar of a similar colour without reading as an
  // outline.
  path := NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius(
    NSInsetRect(pill, 0.5, 0.5), SITEM_RADIUS - 0.5, SITEM_RADIUS - 0.5);
  path.setLineWidth(1);
  ToNSColor(e.bg).shadowWithLevel(0.25).colorWithAlphaComponent(0.5).setStroke;
  path.stroke;
  // Centred on the cap height, not the line box: digits carry no
  // descenders, so centring the line would sit them high. drawAtPoint puts
  // the line's bottom (the descender) at the point.
  font := PillFont(SITEM_WEIGHT_VALUE);
  e.text.drawAtPoint(NSMakePoint(SITEM_H_PAD,
    (sz.height - font.capHeight) / 2 + font.descender));
end;

function MenuItem(const caption: string; action: SEL;
  target: TMultiStatusTarget): NSMenuItem;
begin
  Result := NSMenuItem.alloc.initWithTitle_action_keyEquivalent(
    UTF8NS(caption), action, NSSTR(''));
  Result.setTarget(target);
  Result.autorelease;
end;

// Store the text in @param(e) for drawPill and return a pill-sized image
// that draws through it. Autoreleased; the button retains it.
function PillImage(e: TStatusEntry; const Lead, Value, Detail: string;
  bg, textColor: TColor): NSImage;
var
  text: NSMutableAttributedString;
  fg, faded: NSColor;
  rep: NSCustomImageRep;
  w, h: CGFloat;
begin
  fg := ToNSColor(textColor);
  faded := fg.colorWithAlphaComponent(SITEM_FADED_ALPHA);
  text := NSMutableAttributedString.alloc.init;
  if Lead <> '' then
    text.appendAttributedString(Run(Lead + ' ', PillFont(SITEM_WEIGHT_FADED), faded));
  text.appendAttributedString(Run(Value, PillFont(SITEM_WEIGHT_VALUE), fg));
  if Detail <> '' then
    text.appendAttributedString(Run(' ' + Detail, PillFont(SITEM_WEIGHT_FADED), faded));
  if e.text <> nil then
    e.text.release;
  e.text := text; // owned from alloc
  e.bg := bg;

  h := NSStatusBar.systemStatusBar.thickness - 2 * SITEM_V_INSET;
  if h < SITEM_MIN_H then
    h := SITEM_MIN_H
  else if h > SITEM_MAX_H then
    h := SITEM_MAX_H;
  // Whole points, so the pill edges land on pixel boundaries.
  w := Round(text.size.width + 0.5) + 2 * SITEM_H_PAD;

  rep := NSCustomImageRep.alloc.initWithDrawSelector_delegate(
    objcselector('drawPill:'), e.target);
  rep.setSize(NSMakeSize(w, h));
  Result := NSImage.alloc.initWithSize(NSMakeSize(w, h));
  Result.addRepresentation(rep);
  rep.release;
  Result.autorelease;
  Result.setTemplate(false);
end;

class function TMultiStatusNative.SupportsStatusItem: boolean;
begin
  Result := true;
end;

// Through a suite rather than CFPreferences, so the answer comes from the
// cache the Dock itself writes to; a missing key reads as false.
class function TMultiStatusNative.StatusItemDefault: boolean;
var
  dock: NSUserDefaults;
begin
  Result := false;
  dock := NSUserDefaults.alloc.initWithSuiteName(NSSTR('com.apple.dock'));
  if dock = nil then
    Exit;
  try
    Result := dock.boolForKey(NSSTR('autohide'));
  finally
    dock.release;
  end;
end;

procedure TMultiStatusNative.SetStatusItemMenu(const key: string;
  const showCaption, hideCaption, quitCaption: string;
  const onShow, onHide, onQuit: TTrndiWakeCallback);
var
  e: TStatusEntry;
begin
  e := Entry(key, true);
  if e.showBridge = nil then
  begin
    e.showBridge := TTrndiWakeBridge.Create;
    e.hideBridge := TTrndiWakeBridge.Create;
    e.quitBridge := TTrndiWakeBridge.Create;
  end;
  e.showBridge.Callback := onShow;
  e.hideBridge.Callback := onHide;
  e.quitBridge.Callback := onQuit;

  if e.menu = nil then
  begin
    e.menu := NSMenu.alloc.init;
    e.menu.setAutoenablesItems(false);
    e.showItem := MenuItem(showCaption, objcselector('showClicked:'), e.target);
    e.hideItem := MenuItem(hideCaption, objcselector('hideClicked:'), e.target);
    e.quitItem := MenuItem(quitCaption, objcselector('quitClicked:'), e.target);
    e.menu.addItem(e.showItem);
    e.menu.addItem(e.hideItem);
    e.menu.addItem(NSMenuItem.separatorItem);
    e.menu.addItem(e.quitItem);
  end
  else
  begin
    // The menu retains its items, so these references stay valid.
    e.showItem.setTitle(UTF8NS(showCaption));
    e.hideItem.setTitle(UTF8NS(hideCaption));
    e.quitItem.setTitle(UTF8NS(quitCaption));
  end;

  if e.item <> nil then
    e.item.setMenu(e.menu);
end;

function TMultiStatusNative.ShowStatusItem(const key, Lead, Value,
  Detail: string; bg, textColor: TColor): boolean;
var
  e: TStatusEntry;
  tip: string;
begin
  Result := false;
  if Value = '' then
  begin
    HideStatusItem(key);
    Exit;
  end;

  e := Entry(key, true);
  if e.item = nil then
  begin
    // statusItemWithLength hands back an item we do not own; keep our own
    // reference until HideStatusItem removes it.
    e.item := NSStatusBar.systemStatusBar.statusItemWithLength(
      NSVariableStatusItemLength);
    if e.item = nil then
      Exit;
    e.item.retain;
    if e.menu <> nil then
      e.item.setMenu(e.menu);
  end;
  if e.item.button = nil then
    Exit;

  e.item.button.setImage(PillImage(e, Lead, Value, Detail, bg, textColor));
  tip := Value;
  if Lead <> '' then
    tip := Lead + ': ' + tip;
  if Detail <> '' then
    tip := tip + ' ' + Detail;
  e.item.button.setToolTip(UTF8NS(tip));
  Result := true;
end;

procedure TMultiStatusNative.HideStatusItem(const key: string);
var
  e: TStatusEntry;
begin
  e := Entry(key, false);
  if (e = nil) or (e.item = nil) then
    Exit;
  NSStatusBar.systemStatusBar.removeStatusItem(e.item);
  e.item.release;
  e.item := nil;
end;

{$ELSE}

class function TMultiStatusNative.SupportsStatusItem: boolean;
begin
  Result := false;
end;

class function TMultiStatusNative.StatusItemDefault: boolean;
begin
  Result := false;
end;

procedure TMultiStatusNative.SetStatusItemMenu(const key: string;
  const showCaption, hideCaption, quitCaption: string;
  const onShow, onHide, onQuit: TTrndiWakeCallback);
begin
end;

function TMultiStatusNative.ShowStatusItem(const key, Lead, Value,
  Detail: string; bg, textColor: TColor): boolean;
begin
  Result := false;
end;

procedure TMultiStatusNative.HideStatusItem(const key: string);
begin
end;

{$ENDIF}

end.
