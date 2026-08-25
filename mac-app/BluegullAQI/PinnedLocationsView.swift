import SwiftUI
import BluegullAQIKit

/// Add/remove/rename pinned zip codes or addresses (bluegull-aqi-e70.5),
/// geocoded via `LocationResolver` and persisted through
/// `PinnedLocationsStore` -- the App Group, not `UserDefaults.standard`,
/// since the widget's future per-instance location configuration
/// (bluegull-aqi-mtm.3) needs to read this same list.
///
/// Composed into `SettingsView` (bluegull-aqi-e70.9), reachable via
/// `AQIPopoverView`'s gear icon.
struct PinnedLocationsView: View {
    @State private var locations: [PinnedLocation] = []
    @State private var newLabel = ""
    @State private var newAddress = ""
    @State private var errorMessage: String?
    @State private var isResolving = false

    private let store: PinnedLocationsStore
    private let resolver: LocationResolver

    init(store: PinnedLocationsStore = PinnedLocationsStore(), resolver: LocationResolver = LocationResolver()) {
        self.store = store
        self.resolver = resolver
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Fixed white, not adaptive `.primary` (bluegull-aqi-a22) --
            // this section sits well below SettingsView's own top row, over
            // AppBrand's dark lower gradient.
            Text("Pinned Locations")
                .font(.headline)
                .foregroundStyle(.white)

            // Real confusion Steve hit directly: these looked like they
            // should affect the menu bar/popover somehow, but they don't
            // -- only each desktop widget's own per-instance "Edit
            // Widget" configuration reads this list (bluegull-aqi-mtm.3).
            // The menu bar's own location picker (bluegull-aqi-e70.21)
            // reads the exact same list, but its selection is completely
            // independent of any widget's.
            //
            // bluegull-aqi-e70.33: without `.fixedSize(horizontal: false,
            // vertical: true)`, this Text truncated with an ellipsis
            // instead of wrapping onto multiple lines -- same bug, same
            // fix as `AttributionAndDisclaimerText`/`TimestampCaption`'s
            // own doc comments elsewhere in this codebase (a `Text`
            // constrained by an ancestor's fixed-width frame -- here
            // SettingsView's own `.frame(minWidth:idealWidth:)` -- clips
            // to one line by default unless told to size for its wrapped
            // content instead).
            Text("Each desktop widget can be set to show one of these locations (or Current Location) individually — right-click the widget and choose Edit Widget. The menu bar's own location, set from its location picker, is separate.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            // bluegull-aqi-a22: capped at `maxListHeight` (~10 rows) and
            // scrollable past that -- Steve: "we're going to run out of
            // screen height at some point... 10 visible should be enough."
            // Only the list itself scrolls; the caption above and the Add
            // row below stay fixed/always visible, same as a native
            // macOS list-plus-controls layout.
            ScrollView {
                // bluegull-aqi-a22: `.frame(maxWidth: .infinity, alignment:
                // .leading)`, not left unconstrained -- confirmed live,
                // Steve, 2026-08-25 (screenshot): without this, ScrollView
                // doesn't pin its content to its own visible width, so each
                // row's `Spacer()` expanded toward an effectively unbounded
                // canvas instead of the ~360pt actually on screen -- the
                // Name field stretched to fill that phantom width and the
                // trailing trash button, pushed to the far edge of it, then
                // rendered clipped/misplaced relative to what's actually
                // visible. This pins the VStack to the ScrollView's real
                // width so each row's Spacer has a genuine bound to push
                // against.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(locations) { pinned in
                        HStack {
                            // bluegull-aqi-a22: explicit width, not
                            // whatever `.roundedBorder`'s own unconstrained
                            // ideal width happens to be -- an unconstrained
                            // TextField was one of this panel's own
                            // drivers pushing SettingsView's actual width
                            // well past its `.frame(idealWidth:)`
                            // (bluegull-aqi-e70.45) -- a `minWidth`/
                            // `idealWidth` pair is a floor, not a ceiling;
                            // nothing stopped a hungry child from reporting
                            // a larger natural size that the window then
                            // grew to fit. 210, not the original 140 --
                            // Steve asked for these ~50% wider once they
                            // were made this explicit.
                            TextField("Name", text: labelBinding(for: pinned))
                                .brandFieldStyle()
                                .frame(maxWidth: 210)
                            Spacer()
                            Button(role: .destructive) {
                                remove(pinned)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // bluegull-aqi-a22: a FIXED `height`, not just a `maxHeight`
            // ceiling -- confirmed live, Steve, 2026-08-25: with only
            // `maxHeight`, this ScrollView's reported size still tracked
            // its actual content height (0 rows on first layout, before
            // `.onAppear` below finishes `store.load()`; the real list --
            // 11 rows for Steve -- only populates a beat later). Whatever
            // sized this window at that first, empty-list pass didn't
            // revisit it once `locations` grew, so the ScrollView (the
            // most compressible child in this VStack, being the only one
            // without a hard minimum) got squeezed into whatever leftover
            // space remained in that already-fixed window -- Steve saw
            // just the top half of one row, with barely enough scrollbar
            // to matter. A CONSTANT height, independent of `locations.count`
            // entirely, means this section's contribution to SettingsView's
            // own ideal size is the same whether there are 0 pins or 50,
            // so the window is sized correctly from the very first layout
            // pass and never needs to "grow into" a longer list later.
            .frame(height: maxListHeight)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // bluegull-aqi-a22: Name and Address stacked on their own
            // lines, not side by side in one HStack -- Steve's own
            // suggestion: two full-width-ish text fields plus a button
            // all in one row was the other main driver of the oversized
            // window (see the ForEach row's own comment above on why
            // unconstrained TextFields do that). Explicit widths here too,
            // same reasoning, both 50% wider than this fix's first pass
            // per Steve's live follow-up -- a zip code or short address
            // still fits and can scroll within the field if it's longer.
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name (e.g. Home)", text: $newLabel)
                    .brandFieldStyle()
                    .frame(maxWidth: 210)
                    .accessibilityIdentifier("newPinnedLocationLabelField")
                HStack {
                    TextField("Address or zip code", text: $newAddress)
                        .brandFieldStyle()
                        .frame(maxWidth: 270)
                        .accessibilityIdentifier("newPinnedLocationAddressField")
                    // bluegull-aqi-a22: `.borderedProminent`, not the
                    // plain default style -- confirmed live, Steve,
                    // 2026-08-25: SettingsView's own panel-wide
                    // `.tint(AppBrand.midBlue)` (for the trash button and
                    // the fields to visibly match) also recolors a plain
                    // button's TEXT to that same blue, which read as
                    // low-contrast against the similarly-blue surroundings,
                    // especially once the window is key/focused (a
                    // background-window button dims to gray, which
                    // happened to look fine, masking this while unfocused).
                    // `.borderedProminent` fills with the tint instead and
                    // auto-picks a contrasting (white) label color, so it
                    // can't land on a same-hue-as-background text color.
                    Button("Add") {
                        Task { await add() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newLabel.isEmpty || newAddress.isEmpty || isResolving)
                    .accessibilityIdentifier("addPinnedLocationButton")
                }
            }
        }
        .onAppear { locations = store.load() }
    }

    // ~10 rows (bluegull-aqi-a22, Steve's own number) at this row's actual
    // height (brandFieldStyle's padded TextField, ~30pt) plus the
    // ForEach VStack's own 4pt spacing between rows.
    private let maxListHeight: CGFloat = 340

    private func labelBinding(for pinned: PinnedLocation) -> Binding<String> {
        Binding(
            get: { pinned.label },
            set: { rename(pinned, to: $0) }
        )
    }

    private func add() async {
        isResolving = true
        errorMessage = nil
        defer { isResolving = false }

        do {
            let resolvedLocation = try await resolver.resolve(address: newAddress)
            locations.append(PinnedLocation(label: newLabel, location: resolvedLocation))
            store.save(locations)
            newLabel = ""
            newAddress = ""
        } catch {
            errorMessage = "Couldn't find that address."
        }
    }

    private func remove(_ pinned: PinnedLocation) {
        locations.removeAll { $0.id == pinned.id }
        store.save(locations)
    }

    private func rename(_ pinned: PinnedLocation, to newLabel: String) {
        guard let index = locations.firstIndex(where: { $0.id == pinned.id }) else { return }
        locations[index].label = newLabel
        store.save(locations)
    }
}
