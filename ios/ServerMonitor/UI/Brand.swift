import SwiftUI

/// The appinsource wordmark. Always lowercase; only "in" is blue.
///  - dark mode:  app/source white, "in" PayPal blue  #009CDE
///  - light mode: app/source black, "in" darker blue   #0070BA
enum Brand {
    static let name = "appinsource"
    static let blueDark = Color(hex: 0x009CDE)
    static let blueLight = Color(hex: 0x0070BA)
}

struct BrandWordmark: View {
    var size: CGFloat = 20
    var weight: Font.Weight = .bold
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let base: Color = scheme == .dark ? .white : .black
        let blue = scheme == .dark ? Brand.blueDark : Brand.blueLight
        (Text("app").foregroundColor(base) + Text("in").foregroundColor(blue) + Text("source").foregroundColor(base))
            .font(.system(size: size, weight: weight))
            .accessibilityLabel(Brand.name)
    }
}
