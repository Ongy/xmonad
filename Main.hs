-----------------------------------------------------------------------------
-- |
-- Module      :  Main.hs
-- Copyright   :  (c) Spencer Janssen 2007
-- License     :  BSD3-style (see LICENSE)
--
-- Maintainer  :  sjanssen@cse.unl.edu
-- Stability   :  unstable
-- Portability :  not portable, uses mtl, X11, posix
--
-- xmonad, a minimalist, tiling window manager for X11
-- 
-----------------------------------------------------------------------------

module Main where

import Data.Bits
import qualified Data.Map as M
import qualified Data.Set as S
import Control.Monad.Reader
import Control.Monad.State
import Data.Maybe (fromMaybe)

import System.Environment (getArgs)

import Graphics.X11.Xlib hiding (refreshKeyboardMapping)
import Graphics.X11.Xlib.Extras
import Graphics.X11.Xinerama    (getScreenInfo)

import XMonad
import Config
import StackSet (new, floating, member)
import qualified StackSet as W
import Operations

import System.IO

-- |
-- The main entry point
--
main :: IO ()
main = do
    dpy   <- openDisplay ""
    let dflt = defaultScreen dpy

    rootw  <- rootWindow dpy dflt
    xinesc <- getScreenInfo dpy
    nbc    <- initColor dpy normalBorderColor
    fbc    <- initColor dpy focusedBorderColor
    hSetBuffering stdout NoBuffering
    args <- getArgs

    let winset | ("--resume" : s : _) <- args
               , [(x, "")]            <- reads s = x
               | otherwise = new (fst safeLayouts) workspaces $ zipWith SD xinesc gaps
        gaps = take (length xinesc) $ defaultGaps ++ repeat (0,0,0,0)

        safeLayouts = case defaultLayouts of [] -> (SomeLayout Full, []); (x:xs) -> (x,xs)
        cf = XConf
            { display       = dpy
            , theRoot       = rootw
            , normalBorder  = nbc
            , focusedBorder = fbc }
        st = XState
            { windowset     = winset
            , mapped        = S.empty
            , waitingUnmap  = M.empty
            , dragging      = Nothing }

    xSetErrorHandler -- in C, I'm too lazy to write the binding: dons

    -- setup initial X environment
    sync dpy False
    selectInput dpy rootw $  substructureRedirectMask .|. substructureNotifyMask
                         .|. enterWindowMask .|. leaveWindowMask .|. structureNotifyMask
    grabKeys dpy rootw
    grabButtons dpy rootw

    sync dpy False

    ws <- scan dpy rootw -- on the resume case, will pick up new windows
    allocaXEvent $ \e ->
        runX cf st $ do

            -- walk workspace, resetting X states/mask for windows
            -- TODO, general iterators for these lists.
            sequence_ [ setInitialProperties w >> reveal w
                      | wk <- map W.workspace (W.current winset : W.visible winset)
                      , w  <- W.integrate' (W.stack wk) ]

            sequence_ [ setInitialProperties w >> hide w
                      | wk <- W.hidden winset
                      , w  <- W.integrate' (W.stack wk) ]

            mapM_ manage ws -- find new windows
            refresh

            -- main loop, for all you HOF/recursion fans out there.
            forever $ handle =<< io (nextEvent dpy e >> getEvent e)

      where forever a = a >> forever a

-- ---------------------------------------------------------------------
-- IO stuff. Doesn't require any X state
-- Most of these things run only on startup (bar grabkeys)

-- | scan for any new windows to manage. If they're already managed,
-- this should be idempotent.
scan :: Display -> Window -> IO [Window]
scan dpy rootw = do
    (_, _, ws) <- queryTree dpy rootw
    filterM ok ws
  -- TODO: scan for windows that are either 'IsViewable' or where WM_STATE ==
  -- Iconic
  where ok w = do wa <- getWindowAttributes dpy w
                  a  <- internAtom dpy "WM_STATE" False
                  p  <- getWindowProperty32 dpy a w
                  let ic = case p of
                            Just (3:_) -> True -- 3 for iconified
                            _          -> False
                  return $ not (wa_override_redirect wa)
                         && (wa_map_state wa == waIsViewable || ic)

-- | Grab the keys back
grabKeys :: Display -> Window -> IO ()
grabKeys dpy rootw = do
    ungrabKey dpy anyKey anyModifier rootw
    forM_ (M.keys keys) $ \(mask,sym) -> do
         kc <- keysymToKeycode dpy sym
         -- "If the specified KeySym is not defined for any KeyCode,
         -- XKeysymToKeycode() returns zero."
         when (kc /= '\0') $ mapM_ (grab kc . (mask .|.)) extraModifiers

  where grab kc m = grabKey dpy kc m rootw True grabModeAsync grabModeAsync

grabButtons :: Display -> Window -> IO ()
grabButtons dpy rootw = do
    ungrabButton dpy anyButton anyModifier rootw
    mapM_ (\(m,b) -> mapM_ (grab b . (m .|.)) extraModifiers) (M.keys mouseBindings)
  where grab button mask = grabButton dpy button mask rootw False buttonPressMask
                                      grabModeAsync grabModeSync none none

-- ---------------------------------------------------------------------
-- | Event handler. Map X events onto calls into Operations.hs, which
-- modify our internal model of the window manager state.
--
-- Events dwm handles that we don't:
--
--    [ButtonPress]    = buttonpress,
--    [Expose]         = expose,
--    [PropertyNotify] = propertynotify,
--

handle :: Event -> X ()

-- run window manager command
handle (KeyEvent {ev_event_type = t, ev_state = m, ev_keycode = code})
    | t == keyPress = withDisplay $ \dpy -> do
        s  <- io $ keycodeToKeysym dpy code 0
        whenJust (M.lookup (cleanMask m,s) keys) id

-- manage a new window
handle (MapRequestEvent    {ev_window = w}) = withDisplay $ \dpy -> do
    wa <- io $ getWindowAttributes dpy w -- ignore override windows
    -- need to ignore mapping requests by managed windows not on the current workspace
    managed <- isClient w
    when (not (wa_override_redirect wa) && not managed) $ do manage w

-- window destroyed, unmanage it
-- window gone,      unmanage it
handle (DestroyWindowEvent {ev_window = w}) = whenX (isClient w) $ unmanage w

-- We track expected unmap events in waitingUnmap.  We ignore this event unless
-- it is synthetic or we are not expecting an unmap notification from a window.
handle (UnmapEvent {ev_window = w, ev_send_event = synthetic}) = whenX (isClient w) $ do
    e <- gets (fromMaybe 0 . M.lookup w . waitingUnmap)
    if (synthetic || e == 0)
        then unmanage w
        else modify (\s -> s { waitingUnmap = M.adjust pred w (waitingUnmap s) })

-- set keyboard mapping
handle e@(MappingNotifyEvent {ev_window = w}) = do
    io $ refreshKeyboardMapping e
    when (ev_request e == mappingKeyboard) $ withDisplay $ io . flip grabKeys w

-- handle button release, which may finish dragging.
handle e@(ButtonEvent {ev_event_type = t})
    | t == buttonRelease = do
    drag <- gets dragging
    case drag of
        -- we're done dragging and have released the mouse:
        Just (_,f) -> modify (\s -> s { dragging = Nothing }) >> f
        Nothing    -> broadcastMessage e

-- handle motionNotify event, which may mean we are dragging.
handle e@(MotionEvent {ev_event_type = _t, ev_x = x, ev_y = y}) = do
    drag <- gets dragging
    case drag of
        Just (d,_) -> d (fromIntegral x) (fromIntegral y) -- we're dragging
        Nothing -> broadcastMessage e

-- click on an unfocused window, makes it focused on this workspace
handle e@(ButtonEvent {ev_window = w,ev_event_type = t,ev_button = b })
    | t == buttonPress = do
    -- If it's the root window, then it's something we
    -- grabbed in grabButtons. Otherwise, it's click-to-focus.
    isr <- isRoot w
    if isr then whenJust (M.lookup (cleanMask (ev_state e), b) mouseBindings) ($ ev_subwindow e)
           else focus w
    sendMessage e -- Always send button events.

-- entered a normal window, makes this focused.
handle e@(CrossingEvent {ev_window = w, ev_event_type = t})
    | t == enterNotify && ev_mode   e == notifyNormal
                       && ev_detail e /= notifyInferior = focus w

-- left a window, check if we need to focus root
handle e@(CrossingEvent {ev_event_type = t})
    | t == leaveNotify
    = do rootw <- asks theRoot
         when (ev_window e == rootw && not (ev_same_screen e)) $ setFocusX rootw

-- configure a window
handle e@(ConfigureRequestEvent {ev_window = w}) = withDisplay $ \dpy -> do
    ws <- gets windowset
    wa <- io $ getWindowAttributes dpy w

    if M.member w (floating ws)
        || not (member w ws)
        then do io $ configureWindow dpy w (ev_value_mask e) $ WindowChanges
                    { wc_x            = ev_x e
                    , wc_y            = ev_y e
                    , wc_width        = ev_width e
                    , wc_height       = ev_height e
                    , wc_border_width = fromIntegral borderWidth
                    , wc_sibling      = ev_above e
                    , wc_stack_mode   = ev_detail e }
                when (member w ws) (float w)
        else io $ allocaXEvent $ \ev -> do
                 setEventType ev configureNotify
                 setConfigureEvent ev w w
                     (wa_x wa) (wa_y wa) (wa_width wa)
                     (wa_height wa) (ev_border_width e) none (wa_override_redirect wa)
                 sendEvent dpy w False 0 ev
    io $ sync dpy False

-- the root may have configured
handle (ConfigureEvent {ev_window = w}) = whenX (isRoot w) rescreen

handle e = broadcastMessage e -- trace (eventName e) -- ignoring
