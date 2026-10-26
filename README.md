# CatCursorLock for macOS

Small macOS menu-bar-less input lock derived from [choiyounggi/mac-inputlock](https://github.com/choiyounggi/mac-inputlock), released under MIT (see `LICENSE`).

## Behavior

- **Control + Option + Command + L**: toggle on/off. A held `L` causes *one* toggle until released; repeats are ignored. The shortcut's key-up is also suppressed.
- Locked: block keyboard, modifier keys, mouse and trackpad **clicks**, button press/release, scroll wheel and drag actions.
- **Cursor continues to move** with the mouse or touchpad. Drag events are converted to ordinary mouse-move events so movement also works when a button is physically held.
- **No unlock timer** and **no display sleep prevention**. macOS controls display idle/sleep normally, and may lock its session according to System Settings. If the Mac sleeps and asks for a password on wake, that's macOS, not this utility.
- When the active process terminates, its event tap disappears and input is released. A waiting agent can then take over, and launchd restarts a managed agent after it exits; each new active instance starts unlocked. The utility is **not a security lock**.
- Some macOS system-level multi-touch gestures, secure input and shortcuts may bypass `CGEventTap`.
- Only one instance can intercept input per user. An ordinary duplicate launch exits successfully before requesting permissions or connecting to input events.

## Build entirely locally (macOS 13+)

Requires a Mac with the Xcode Command Line Tools (or Xcode), including `swiftc`. Unpack the source, then run from the project directory:

```sh
bash -n build.sh
bash build.sh 1.0.0
```

Outputs `CatCursorLock.app` and `CatCursorLock-1.0.0.zip` in the project directory. Uses macOS `swiftc`, `codesign`, `ditto`, `shasum`; no external dependencies, downloads or network calls in the build script. The default ad-hoc code signature is suitable for personal local builds; it is not notarization.

Run the bundle:

```sh
open ./CatCursorLock.app
```

Grant **System Settings → Privacy & Security → Accessibility** to `CatCursorLock.app`. If the permission is not immediately effective, quit and reopen the app. It's an LSUIElement background app with no window/menu.

**Avoid running another input-locking daemon simultaneously** until the new hotkey and recovery method have been tested.

## Optional login auto-start

Move `CatCursorLock.app` to a stable location **before** installing autostart. The commands below assume `/Applications/CatCursorLock.app`:

```sh
/Applications/CatCursorLock.app/Contents/MacOS/catcursorlock --install-agent
```

To remove:

```sh
/Applications/CatCursorLock.app/Contents/MacOS/catcursorlock --uninstall-agent
```

Autostart only works if the `.app` remains at the *same stable path*. If you choose another location, invoke the binary from that location instead; quote paths containing spaces or shell special characters. `--install-agent` writes `~/Library/LaunchAgents/local.catcursorlock.plist`, and the managed agent logs to `~/Library/Logs/catcursorlock.log`; ordinary launches and the build script do not install the agent.

Installing again updates the registered executable path and restarts the managed agent. If a manually launched instance is already running, the agent waits without intercepting input until that instance exits, then starts unlocked. Uninstalling stops the managed agent (including a waiting agent) and removes its plist; a manually launched instance continues running.

Run both management commands as your own user in an active macOS GUI login session, without `sudo`. They return `0` on success and `1` on failure, with an error on standard error. Uninstalling an already absent agent succeeds when the GUI login domain is available. Concurrent install/uninstall operations are rejected with an error; retry once the other operation finishes. Installation success confirms launchd registration; Accessibility permission is still required for input interception.

Instance and management locks are stored in `~/Library/Application Support/CatCursorLock/`. The OS releases the locks on process exit, including crashes. The files remain in place and should not be removed while the app or management commands are running.

## Stop the app

Unlock with **Control + Option + Command + L**, then uninstall the login agent if installed. To stop a remaining manually launched instance, use Activity Monitor or run:

```sh
killall catcursorlock
```

For a foreground launch from Terminal, `Ctrl+C` also works while unlocked. While locked, keyboard input including `Ctrl+C` is blocked. If the toggle does not work, terminate the process from another session or restart macOS. Terminating a managed agent without uninstalling it causes launchd to restart it unlocked.

## Testing checklist on Mac

1. Start app. Confirm hotkey switches lock on/off exactly once per key press, including when holding `L` down.
2. While locked, move pointer with one finger or a mouse; pointer should move.
3. While locked, click/tap/drag/scroll and type ordinary keys; no actions should reach open apps.
4. While locked, press and hold mouse/trackpad button while moving; pointer should move without dragging UI objects.
5. Leave locked longer than 10 minutes while keeping the screen awake normally: it should stay locked. Test sleep/wake separately, as macOS security dialogs may behave differently.
6. Verify process termination and input recovery using the methods in **Stop the app**. With autostart installed, verify that terminating the managed agent restarts it unlocked; uninstall it to stop it permanently.
7. Launch the executable again while the first instance is running: it should exit with code `0`, and the original instance's hotkey should still lock/unlock normally.
8. If using autostart, install it while a manual instance is running. The log should show the agent waiting; after the manual instance exits, the agent should become active. Repeat installation, then uninstall twice; all successful commands should return `0`.
9. Test installation from a stable path containing `&` (after removing the previous registration). The generated plist should pass `plutil -lint ~/Library/LaunchAgents/local.catcursorlock.plist`; registration should succeed. Uninstall before moving or deleting this test bundle.
10. For failure reporting, run an install/uninstall command outside a GUI login session (for example, in an SSH-only session for a test account without a GUI login): a launchd domain error should return `1`, with no success message. A failed install may leave the plist on disk; uninstall it in that account's GUI session afterward.

## Scope and limitations

- The original project's global `CGEventTap` architecture is retained. Not tested on macOS in this environment; compile and functional testing must be performed on a Mac.
- The lock state is in memory, initially `false` on every launch. No automatic timed unlock exists. Activate the lock when no other keys or mouse buttons are held; releases of inputs pressed before locking are not reconciled with applications.
- `CGEventTap` cannot promise that *all* macOS gestures or protected system interactions are blocked.
- No collection or storage of keystrokes, network functions, external dependencies, automatic downloads or phone-home behavior was added.

## License

MIT, inherited from the original project; see `LICENSE`.
