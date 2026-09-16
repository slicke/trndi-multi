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
  Markdown for the dialogs, rendered by the vendored Pixie engine
  (vendor/pixie, MIT): the terms, the empty wall, the accounts window's
  notes and the update dialog are prose with headings, lists and links,
  which a TLabel or TMemo cannot show. Everything stays Pascal: Pixie is
  an HTML/CSS layout engine without JavaScript, drawn through the LCL's
  own widgetset (QPainter, Cairo, Core Graphics or Direct2D).
}
unit trndimulti.markdown;

{$mode objfpc}{$H+}

interface

uses
Classes, Controls, Graphics, Pixie.MarkdownView;

type
  {** A Markdown view for a dialog: no border, links open in the browser,
      styled to sit on a given background rather than as a web page. }
  TMarkdownPane = class(TPixieMarkdownView)
  private
    procedure LinkClick(Sender: TObject; El: TObject; const Url: string);
  public
    constructor Create(AOwner: TComponent); override;
    {** Colours and base size of the text. @param(extraCss) is appended
        for a caller's own rules. Set before @link(Load). }
    procedure SetTheme(bg, fg: TColor; fontPx: integer;
      const extraCss: string = '');
    {** Show @param(md); an empty string clears the pane. }
    procedure Load(const md: string);
  end;

{** A TColor as CSS: '#rrggbb'. System colours are resolved first. }
function CssColor(c: TColor): string;

implementation

uses
SysUtils, LCLIntf;

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
  // Pixie's GitHub-like stylesheet is for pages; the dialog's own rules
  // (SetTheme) go through UserCss instead.
  UseDefaultStyles := false;
  OnAnchorClick := @LinkClick;
end;

procedure TMarkdownPane.SetTheme(bg, fg: TColor; fontPx: integer;
  const extraCss: string);
begin
  Color := bg;
  UserCss :=
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
  LoadMarkdownFromString(md);
end;

procedure TMarkdownPane.LinkClick(Sender: TObject; El: TObject;
  const Url: string);
begin
  if Url <> '' then
    OpenURL(Url);
end;

end.
