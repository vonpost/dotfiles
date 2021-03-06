import XMonad

import XMonad.Actions.Navigation2D
import XMonad.Layout.Fullscreen hiding (fullscreenEventHook)
import XMonad.Layout.BinarySpacePartition
import XMonad.Layout.Spacing
import XMonad.Actions.SpawnOn
import MyKeyBindings
import XMonad.Hooks.EwmhDesktops 
import XMonad.Layout.Tabbed
import XMonad.Hooks.SetWMName
import XMonad.Hooks.ManageHelpers
import XMonad.Util.Scratchpad
import XMonad.Layout.Hidden
import XMonad.Layout.Spacing

main :: IO ()
main =
  xmonad
    $ ewmh
    -- fullscreenSupport
    $ withNavigation2DConfig def { defaultTiledNavigation = hybridOf lineNavigation centerNavigation }
    $ myConfig


-- TODO: Get these colors from xrdb
-- backgroundColor   = "#000000"
-- middleColor       = "#F2A4A3"
-- foregroundColor   = "#F2A4A3"
myConfig = def
  { borderWidth        = 0
  , startupHook = startupHook def
    -- <+> setFullscreenSupported
  , handleEventHook = fullscreenEventHook
  -- , focusedBorderColor = foregroundColor
  , focusFollowsMouse  = False
  , keys               = myKeys
  , layoutHook         = spacingRaw True (Border 10 10 10 10) True (Border 10 10 10 10) True
                         $ hiddenWindows emptyBSP 
  , modMask            = mod4Mask
  , manageHook         = manageSpawn <+> manageHook def <+> scratchpadManageHookDefault <+> fullscreenManageHook  
  -- , normalBorderColor  = middleColor
  , terminal           = "urxvtc"
  , workspaces         = [ "browse", "code", "read", "chat", "etc"]
  -- TODO: Fix workspaces, correct names, started in correct workspaces etc.
  -- startupHook = do
  --      spawnOn "etc" "steam"
  --      spawnOn "browse" "google-chrome"
  --      spawnOn "code" "emacs"
  }


-- Firefox, etc. for fullscreen support.
setFullscreenSupported :: X ()
setFullscreenSupported = withDisplay $ \dpy -> do
    r <- asks theRoot
    a <- getAtom "_NET_SUPPORTED"
    c <- getAtom "ATOM"
    supp <- mapM getAtom ["_NET_WM_STATE_HIDDEN"
                         ,"_NET_WM_STATE_FULLSCREEN" -- XXX Copy-pasted to add this line
                         ,"_NET_NUMBER_OF_DESKTOPS"
                         ,"_NET_CLIENT_LIST"
                         ,"_NET_CLIENT_LIST_STACKING"
                         ,"_NET_CURRENT_DESKTOP"
                         ,"_NET_DESKTOP_NAMES"
                         ,"_NET_ACTIVE_WINDOW"
                         ,"_NET_WM_DESKTOP"
                         ,"_NET_WM_STRUT"
                         ]
    io $ changeProperty32 dpy r a c propModeReplace (fmap fromIntegral supp)

    setWMName "xmonad"
