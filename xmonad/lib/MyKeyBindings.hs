
module MyKeyBindings where

import XMonad

import XMonad.Actions.CycleWS
import XMonad.Actions.Navigation2D

import XMonad.Layout.BinarySpacePartition

import XMonad.Util.CustomKeys
import XMonad.Util.Run
import Graphics.X11.ExtraTypes.XF86

myKeys = customKeys removedKeys addedKeys

removedKeys :: XConfig l -> [(KeyMask, KeySym)]
removedKeys XConfig {modMask = modm} =
    [ --(modm              , xK_space)  -- Default for layout switching
      (modm .|. shiftMask, xK_Return) -- Default for opening a terminal
    , (modm .|. shiftMask, xK_c)      -- Default for closing the focused window
    ]

addedKeys :: XConfig l -> [((KeyMask, KeySym), X ())]
addedKeys conf @ XConfig {modMask = modm} =
  [ -- Application launcher
    ((0, 0xff61) , spawn "rofi -combi-modi window,drun -show combi -modi combi")

    -- Terminal
  , ((modm, xK_Return), spawn $ XMonad.terminal conf)

    -- Close application
  , ((modm, xK_w), kill)

    -- Switch to last workspace
  , ((modm, xK_Tab), toggleWS)

    -- Rotate windows
  , ((modm, xK_r), sendMessage Rotate)

    -- Swap windows
  , ((modm, xK_t), sendMessage Swap)

    -- Layout switching
  --, ((modm .|. shiftMask, xK_t), sendMessage NextLayout)

    -- Directional navigation of windows
  , ((modm, xK_Right), windowGo R False)
  , ((modm, xK_Left), windowGo L False)
  , ((modm, xK_Up), windowGo U False)
  , ((modm, xK_Down), windowGo D False)

    -- Go to workspace, show which one
  , ((modm, xK_1), sequence_ [toggleOrView "browse", spawn "notify-send \"browse\""])
  , ((modm, xK_2), sequence_ [toggleOrView "code"  , spawn "notify-send \"code\""  ])
  , ((modm, xK_3), sequence_ [toggleOrView "read"  , spawn "notify-send \"read\""  ])
  , ((modm, xK_4), sequence_ [toggleOrView "chat"  , spawn "notify-send \"chat\""  ])
  , ((modm, xK_5), sequence_ [toggleOrView "etc"   , spawn "notify-send \"etc\""   ])

    -- Expand and shrink windows
  , ((modm .|. shiftMask,                xK_Right), sendMessage $ ExpandTowards R)
  , ((modm .|. shiftMask,                xK_Left), sendMessage $ ExpandTowards L)
  , ((modm .|. shiftMask,                xK_Down), sendMessage $ ExpandTowards D)
  , ((modm .|. shiftMask,                xK_Up), sendMessage $ ExpandTowards U)
  , ((modm .|. controlMask , xK_Right), sendMessage $ ShrinkFrom R)
  , ((modm .|. controlMask , xK_Left), sendMessage $ ShrinkFrom L)
  , ((modm .|. controlMask , xK_Down), sendMessage $ ShrinkFrom D)
  , ((modm .|. controlMask , xK_Up), sendMessage $ ShrinkFrom U)

    -- Toggle keyboard layouts
 , ((0, xF86XK_Search), toggleLanguage)

    -- Brightness control
  , ((0, xF86XK_MonBrightnessUp), incLight)
  , ((0, xF86XK_MonBrightnessDown), decLight)
  , ((0, xF86XK_Display), toggleLight)

    --XF86AudioMicMute
  , ((0, xF86XK_AudioMicMute), spawn "amixer -q sset Capture toggle")
    -- XF86AudioMute
  , ((0, xF86XK_AudioMute), spawn "amixer set Master toggle ")

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
  , ((0, xF86XK_LaunchA ), spawn "maim -s | xclip -selection clipboard -t image/png")
  ]



-- some help functions
readLight = do brightness <- runProcessWithInput "xbacklight" ["-get"] ""
               let rounded = show . round $ read brightness
               spawn $ "notify-send \"" ++ rounded ++ "\""


incLight = spawn "xbacklight -inc 5" >> readLight
decLight = spawn "xbacklight -dec 5" >> readLight

switchLight :: Int -> String
switchLight percent = if percent > 0 then "0" else "5"
toggleLight = do brightness:_ <- runProcessWithInput "xbacklight" ["-get"] ""
                 let cmd = "xbacklight -set " ++ (switchLight (read [brightness]))
                 spawn cmd






languages = ["se", "us"]
toggleLanguage = do status <- runProcessWithInput "setxkbmap" ["-query"] ""
                    let _:currentLanguage:_ = words . head . drop 2 $ lines status
                    let language:_ = filter (\x -> x /= currentLanguage) languages
                    spawn $ "setxkbmap " ++ language ++  " && notify-send \"" ++ language ++ "\""
