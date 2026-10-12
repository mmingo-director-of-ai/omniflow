import Foundation

@main
enum WidgetAppGroupTests {
    static func main() {
        let valid = "A1B2C3D4E5.com.mengohlabs.omniflow"
        precondition(OmniFlowWidgetStore.configuredAppGroup(valid) == valid)
        for value: Any? in [nil, "", "com.mengohlabs.omniflow", ".com.mengohlabs.omniflow",
            "$(TeamIdentifierPrefix)com.mengohlabs.omniflow", "${TeamIdentifierPrefix}com.mengohlabs.omniflow",
            "A1B2C3D4E5.other", "A1B2C3D4E5.com.mengohlabs.omniflow ", "A1B2C3D4E5.com.mengohlabs.omniflow\n", 42] {
            precondition(OmniFlowWidgetStore.configuredAppGroup(value) == nil)
        }
        print("Widget App Group: configured team accepted; missing/unresolved/invalid values rejected")
    }
}
