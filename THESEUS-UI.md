# ThemeBoard — Theseus UI integration

ThemeBoard's app-owned surfaces use the original Theseus renderer. The reference is `https://github.com/valzevul/Theseus`, pinned at `71ca1c127a4e7fe3387361f160c4890dbd427f66`. All 33 Swift source files and the Metal shader are vendored byte-for-byte. LICENSE, NOTICE and the upstream file hashes are in `Vendor/Theseus`; the built app includes the acknowledgements.

## UI coverage

- The three-tab dock uses the original `TheseusTabBar` optics, press lift, drag lens, springs and selection commit. Its height is 64pt, its centered width is the smaller of 312pt and the screen width minus 36pt, and its bottom gap is 34pt. The staged tab component uses equal item slots and a resting capsule up to 96pt wide, with the original native capsule height. A thin bridge preserves theme/settings/status routes and reselect-to-pop behavior.
- Theme lists, settings, state diagnostics, missing-icon lists, detail summaries and icon preview cards share the original `TheseusConfiguration.regular` material through `TBGlassCard`.
- Theme toolbar, sorting, log-folder, navigation actions, keyboard Done and swipe-delete buttons use the same material. Selected/primary states use the upstream tint configuration, with text and existing checks kept as foreground content.
- Confirmation/action/alert/numeric panels, bottom drawers and transient toasts use the same renderer. Their existing callbacks, dismissal, keyboard avoidance, drag anchors and timing remain app behavior.
- Settings switches and both numeric sliders use the original Theseus controls through UIControl adapters. Preference keys and notifications are preserved.
- App-owned search and numeric text-field surfaces use Theseus without replacing UIKit text editing or swizzling search-field layout.
- UIKit navigation, system back gestures, keyboard, document pickers, refresh indicators and system-provided menus retain their platform behavior. Theseus does not provide replacements for those services.

The material is supplied by Theseus. Previous app-owned UIVisualEffectView layers, page backing helpers, background-view cell plates, the unused combined preview card, global swipe-layout replacement and cross-fading tab pages have been removed. One `TBBackdropView` sits below all pages and fills the screen with the selected background 04. Its original light image and derived dark image are bundled locally and switch with the active app appearance. Page, navigation and window backgrounds are clear; UIKit adjusts full-page scroll content for the transparent bars.

## Capture and lifecycle

`TBTheseusSurface` explicitly captures the window, excludes the foreground host (or whole cell) and front sibling branches, and permits lower glass snapshots for nested controls. It uses the original regular preset and the same device/simulator capture method as the upstream controls. A shared visibility pass pauses surfaces outside the window/clipping chain or in hidden tabs/background; visible surfaces update for geometry, initial warmup and at most once a second when static. It does not run every card in continuous render mode. Native scrolling, simultaneous drag, modal stacking, keyboard transitions and actual GPU performance still require device testing.

The dock invalidates its backdrop during visible scrolling and page transitions, and at a lower cadence while idle. VoiceOver activation proxies the original item labels, traits and frames while preserving reselect-to-pop. The slider adapter is a UIControl that composes the final upstream TheseusSlider. It forwards physical begin/continue/end/cancel tracking to the original component and preserves non-continuous accessibility adjustments; it does not inherit or alter TheseusSlider.

## Source cleanup after 1.52 device feedback

`tools/prepare_theseus_sources.py` still verifies the pinned vendor files, but its disposable build copy now changes only the selected tab's geometry. The previous Metal-host, renderer, capture-veil and capture-transaction rewrites have been removed; those staged files, materials and shader are upstream bytes. App host adaptation uses Theseus's shared display-link driver before render callbacks. Parent surfaces notify their nested surfaces after a new capture snapshot is available. Cells place one noninteractive material below their foreground content with their UIKit background configuration cleared.

The cleaned Objective-C UI files pass arm64e syntax checks with existing warnings; the 37 upstream files pass their integrity checks. This revision has not been natively Swift/Metal compiled, packaged, or device tested. The source version remains 1.52; previous delivered packages do not contain this cleanup. These source changes require native visual comparison before claiming device rectangles or flashes are gone.

## Build

Use full Xcode on macOS and `sh tools/build-app.sh`, or explicitly run the `build` workflow. The workflow is manual-only; legacy automatic CI is disabled. Original Swift and the adapters compile as one static Swift object; Metal compiles into `Theseus_Theseus.bundle/default.metallib`. `Integration/TheseusBundle.swift` supplies the Bundle.module accessor normally generated by SwiftPM. Swift runtime support is copied when needed. All resources and nested code are finalized before the app is signed with the existing entitlements.

Run `python3 tools/verify_theseus.py --root .` to verify original upstream files and integration structure. That is a static integrity check, not a native build or visual test.

Version 1.52 builds only arm64e RootHide App and engine for this request; `PACKAGE_ARCH=arm64e` is passed explicitly, and the final verifier rejects unexpected arm64 packages. The unprefixed `Applications`/`Library`/`usr` layout, same-architecture embedded signed engine, full entitlements and Metal resources are checked from the finished debs. A normal arm64 target remains available only on a separately authorized build. Building does not install or publish packages. The iSH host cannot typecheck Apple's Swift/Metal; device visuals require testing the new package.
