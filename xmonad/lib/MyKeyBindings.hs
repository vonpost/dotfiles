
module MyKeyBindings where

import XMonad

import XMonad.Actions.CycleWS
import XMonad.Actions.Navigation2D

import XMonad.Layout.BinarySpacePartition

import XMonad.Util.CustomKeys
import XMonad.Util.Run
import XMonad.Util.Scratchpad
import Graphics.X11.ExtraTypes.XF86
import XMonad.Layout.Hidden
import XMonad.Layout.Spacing
import qualified XMonad.Util.ExtensibleState as XS
myKeys = customKeys removedKeys addedKeys

removedKeys :: XConfig l -> [(KeyMask, KeySym)]
removedKeys XConfig {modMask = modm} =
    [--(modm              , xK_space)  -- Default for layout switching
      (modm .|. shiftMask, xK_Return) -- Default for opening a terminal
    , (modm .|. shiftMask, xK_c)      -- Default for closing the focused window
    ]

addedKeys :: XConfig l -> [((KeyMask, KeySym), X ())]
addedKeys conf @ XConfig {modMask = modm} =
  [ -- Application launcher
    ((0, 0xff61) , spawn "rofi -combi-modi window,drun -show combi -modi combi")

    -- Terminal
  , ((modm, xK_Return), spawn $ XMonad.terminal conf)
    -- Emacs
  , ((modm, xK_e), spawn "emacsclient -c -n -e '(switch-to-buffer nil)'")
    -- Close application
  , ((modm, xK_w), kill)

    -- Modify spacing
  , ((modm, xK_Right), incScreenWindowSpacing 2)
  , ((modm, xK_Left), decScreenWindowSpacing 2)
  , ((modm, xK_Up), toggleScreenSpacingEnabled >> toggleWindowSpacingEnabled)

    -- Switch to last workspace
  , ((modm, xK_Tab), toggleWS)
  , ((modm, xK_u), toggleHidden)
  , ((modm, xK_b), withFocused hideWindow)
  , ((modm, xK_n), popNewestHiddenWindow)
  , ((modm, xK_m), popOldestHiddenWindow)
    -- Rotate windows
  , ((modm, xK_r), sendMessage Rotate)

    -- Swap windows
  , ((modm, xK_t), sendMessage Swap)
    -- Open quake terminal dropdown
  , ((modm, xK_f), scratchpadSpawnActionTerminal "urxvtc")

    -- Open rofi-pass, password selector
  , ((modm, xK_p), spawn "rofi-pass")
    -- Layout switching
  --, ((modm .|. shiftMask, xK_t), sendMessage NextLayout)

    -- Directional navigation of windows
  , ((modm, xK_l), windowGo R False)
  , ((modm, xK_h), windowGo L False)
  , ((modm, xK_k), windowGo U False)
  , ((modm, xK_j), windowGo D False)

    -- Go to workspace, show which one
  , ((modm, xK_1), sequence_ [toggleOrView "browse", spawn "notify-send \"space 1\""])
  , ((modm, xK_2), sequence_ [toggleOrView "code"  , spawn "notify-send \"space 2\""  ])
  , ((modm, xK_3), sequence_ [toggleOrView "read"  , spawn "notify-send \"space 3\""  ])
  , ((modm, xK_4), sequence_ [toggleOrView "chat"  , spawn "notify-send \"space 4\""  ])
  , ((modm, xK_5), sequence_ [toggleOrView "etc"   , spawn "notify-send \"space 5\""   ])

    -- Expand and shrink windows
  , ((modm .|. shiftMask,                xK_l), sendMessage $ ExpandTowards R)
  , ((modm .|. shiftMask,                xK_h), sendMessage $ ExpandTowards L)
  , ((modm .|. shiftMask,                xK_j), sendMessage $ ExpandTowards D)
  , ((modm .|. shiftMask,                xK_k), sendMessage $ ExpandTowards U)
  , ((modm .|. controlMask , xK_l), sendMessage $ ShrinkFrom R)
  , ((modm .|. controlMask , xK_h), sendMessage $ ShrinkFrom L)
  , ((modm .|. controlMask , xK_j), sendMessage $ ShrinkFrom D)
  , ((modm .|. controlMask , xK_k), sendMessage $ ShrinkFrom U)

    -- Toggle keyboard layouts
 , ((0, xF86XK_Search), toggleLanguage)
 , ((modm, xK_i), toggleLanguage)
    -- Brightness control
  , ((0, xF86XK_MonBrightnessUp), incLight)
  , ((0, xF86XK_MonBrightnessDown), decLight)
  , ((0, xF86XK_Display), toggleLight)

    --XF86AudioMicMute
  , ((0, xF86XK_AudioMicMute), spawn "amixer -q sset Capture toggle")
    -- XF86AudioMute
  , ((0, xF86XK_AudioMute), spawn "pamixer -t")

    -- XF86AudioRaiseVolume
  , ((0, xF86XK_AudioRaiseVolume), spawn "pamixer -i 5 && notify-send \"$(pamixer --get-volume) \" ")

    -- XF86AudioLowerVolume
  , ((0, xF86XK_AudioLowerVolume), spawn "pamixer -d 5 && notify-send \"$(pamixer --get-volume) \" ")

    -- Show date
  , ((modm, xK_a), spawn "notify-send \"$(date +%A\\,\\ %d\\ %B\\,\\ %R)\"")

    -- Show battery
  , ((modm, xK_s), spawn "notify-send \"$(acpi)\"")

    -- Screenshots
  , ((0, xF86XK_Explorer ), spawn "maim ~/Pictures/$(date +%s).png")
  , ((0, xF86XK_LaunchA ), spawn "maim -s ~/Pictures/$(date +%s).png")
  ]



-- some help functions
readLight = do brightness <- runProcessWithInput "brightnessctl" ["get"] ""
               max <- runProcessWithInput "brightnessctl" ["m"] ""
               let rounded = show . round $ 100*(read brightness)/(read max)
               spawn $ "notify-send \"" ++ rounded ++ "\""


incLight = spawn "brightnessctl set 5%+" >> readLight
decLight = spawn "brightnessctl set 5%-" >> readLight

switchLight :: Int -> String
switchLight percent = if percent > 0 then "0%" else "100%"
toggleLight = do brightness <- runProcessWithInput "brightnessctl" ["get"] ""
                 max <- runProcessWithInput "brightnessctl" ["m"] ""
                 let currentPercentage = 100*(read brightness)/(read max)
                 let cmd = "brightnessctl set " ++ (switchLight (read brightness))
                 spawn cmd


instance ExtensionClass Bool where
  initialValue = False
toggleHidden' state = if state then (popNewestHiddenWindow) >> return False  else (withFocused hideWindow) >> return True
toggleHidden = do state <- XS.get
                  state' <- toggleHidden' state
                  XS.put state'


languages = ["se", "us"]
toggleLanguage = do status <- runProcessWithInput "setxkbmap" ["-query"] ""
                    let _:currentLanguage:_ = words . head . drop 2 $ lines status
                    let language:_ = filter (\x -> x /= currentLanguage) languages
                    spawn $ "setxkbmap " ++ language ++  " && notify-send \"" ++ language ++ "\""
