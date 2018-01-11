import XMonad

import XMonad.Actions.Navigation2D
import XMonad.Layout.Fullscreen
import XMonad.Layout.BinarySpacePartition
import XMonad.Layout.Spacing
import XMonad.Actions.SpawnOn
import MyKeyBindings


main :: IO ()
main =
  xmonad
    $ withNavigation2DConfig def { defaultTiledNavigation = hybridNavigation }
    $ fullscreenSupport
    $ myConfig


-- TODO: Get these colors from xrdb
backgroundColor   = "#FEFEFE"
middleColor       = "#AEAEAE"
foregroundColor   = "#0E0E0E"

myConfig = def
  { borderWidth        = 1
  , focusedBorderColor = foregroundColor
  , focusFollowsMouse  = False
  , keys               = myKeys
  , layoutHook         = spacingWithEdge 20 emptyBSP
  , modMask            = mod4Mask
  , manageHook         = manageSpawn <+> manageHook def 
  , normalBorderColor  = middleColor
  , terminal           = "urxvt"
  , workspaces         = [ "browse", "code", "read", "chat", "etc"]
  --, startupHook = do
  --      spawnOn "etc" "steam"
  --      spawnOn "browse" "google-chrome"
  --      spawnOn "code" "emacs"
  }

