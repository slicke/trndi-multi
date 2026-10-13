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
  Markdown and HTML for the dialogs, rendered by the vendored LazInk
  controls (vendor/lazink, 0BSD): the terms, the empty wall, the accounts
  window's note, the About window, the update prompt and the detail view
  share one pane class, so each can carry links, emphasis and a table,
  which a TLabel or TMemo cannot show. Everything stays Pascal: LazInk
  draws on the TCanvas and needs no browser engine or runtime library.
}
unit trndimulti.markdown;

{$mode objfpc}{$H+}

interface

uses
Classes, Controls, Graphics, InkPage;

type
  {** A page for a dialog: no border, links open in the browser, styled to
      sit on a given background rather than as a web page. The text is the
      program's own, so raw HTML inside Markdown is allowed through. }
  TMarkdownPane = class(TInkPage)
  private
    procedure LinkClick(Sender: TObject; const Url: string);
    procedure Resource(Sender: TObject; const Url: string;
      Destination: TStream; var Handled: boolean);
  public
    constructor Create(AOwner: TComponent); override;
    {** Colours and base size of the text. @param(extraCss) is appended
        for a caller's own rules. Set before @link(Load). }
    procedure SetTheme(bg, fg: TColor; fontPx: integer;
      const extraCss: string = '');
    {** Show @param(md) as Markdown; an empty string clears the pane. }
    procedure Load(const md: string);
    {** Show @param(html) as a page. }
    procedure LoadHtml(const html: string);
    {** Replace the text of the element with @param(id) in place, keeping
        the reader's scroll position. False when there is no such element. }
    function SetText(const id, s: string): boolean;
  end;

{** A TColor as CSS: '#rrggbb'. System colours are resolved first. }
function CssColor(c: TColor): string;

implementation

uses
SysUtils, LCLIntf, base64, InkDOM, InkMarkdown;

function CssColor(c: TColor): string;
var
  r, g, b: byte;
begin
  RedGreenBlue(ColorToRGB(c), r, g, b);
  Result := Format('#%.2x%.2x%.2x', [r, g, b]);
end;

constructor TMarkdownPane.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BorderStyle := bsNone;
  MarkdownRawHTML := true;
  OnLinkClick := @LinkClick;
  OnResource := @Resource;
end;

procedure TMarkdownPane.SetTheme(bg, fg: TColor; fontPx: integer;
  const extraCss: string);
begin
  Color := bg;
  // LazInk dresses Markdown the way GitHub does, in the control's own
  // colours; these rules sit on top for the dialog's look.
  StyleSheet.Text :=
    'html, body { background: ' + CssColor(bg) + '; }' +
    'body { color: ' + CssColor(fg) + '; font-family: sans-serif; ' +
    'font-size: ' + IntToStr(fontPx) + 'px; line-height: 1.4; ' +
    'margin: 0; padding: 0; }' +
    'p { margin: 0 0 0.7em; }' +
    'ul { margin: 0 0 0.7em; padding-left: 1.4em; }' +
    'li { margin: 0.15em 0; }' +
    'h1, h2, h3 { margin: 0 0 0.5em; line-height: 1.25; }' +
    'h1 { font-size: 1.5em; } h2 { font-size: 1.3em; } h3 { font-size: 1.1em; }' +
    'a { color: inherit; text-decoration: underline; }' +
    'code { font-family: monospace; font-size: 0.95em; }' +
    'hr { border: 0; border-top: 1px solid ' + CssColor(fg) + '; opacity: 0.3; }' +
    extraCss;
end;

procedure TMarkdownPane.Load(const md: string);
begin
  LoadMarkdown(md);
end;

procedure TMarkdownPane.LoadHtml(const html: string);
begin
  TextFormat := itfHTML;
  Source := html;
end;

function TMarkdownPane.SetText(const id, s: string): boolean;
var
  el: TInkNode;
begin
  el := nil;
  if Document <> nil then
    el := Document.GetElementById(id);
  Result := el <> nil;
  if Result then
  begin
    el.TextContent := s;
    DocumentChanged;
  end;
end;

procedure TMarkdownPane.LinkClick(Sender: TObject; const Url: string);
begin
  if Url <> '' then
    OpenURL(Url);
end;

// LazInk fetches an image's bytes through the host and knows no data:
// URLs itself; the logo (see trndimulti.branding) is one, so decode it here.
procedure TMarkdownPane.Resource(Sender: TObject; const Url: string;
  Destination: TStream; var Handled: boolean);
const
  PNG = 'data:image/png;base64,';
var
  raw: string;
begin
  if Copy(Url, 1, Length(PNG)) <> PNG then
    exit;
  raw := DecodeStringBase64(Copy(Url, Length(PNG) + 1, MaxInt));
  if raw <> '' then
    Destination.WriteBuffer(raw[1], Length(raw));
  Handled := true;
end;

end.
