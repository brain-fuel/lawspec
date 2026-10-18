import LawSpecRuntime
extension Example.Gadt {
    static func describe(_ value: Shown) -> String {
        switch value { case .shown(_, let witness): return witness }
    }
}
