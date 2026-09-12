Trndi Multi for macOS - first launch
====================================

Trndi Multi is not signed with an Apple Developer ID and not notarized, so
macOS quarantines the download and refuses to open it, usually saying the
app "is damaged" or "cannot be opened because the developer cannot be
verified". The app is fine; the quarantine flag just needs clearing once.

1. Drag "Trndi Multi" to Applications.
2. Open Terminal (Applications -> Utilities -> Terminal) and run:

       xattr -c "/Applications/Trndi Multi.app"

3. Open Trndi Multi normally.

`xattr -c` removes the com.apple.quarantine attribute Gatekeeper checks. It
changes nothing inside the app and nothing else about your Mac's security.

Trndi Multi reads the accounts from Trndi's own settings on this Mac, so set
up Trndi first if you have not already.
