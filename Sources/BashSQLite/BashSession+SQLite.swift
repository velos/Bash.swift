import BashSwift

public extension BashSession {
    func registerSQLite3() async {
        await register(SQLite3Command.self)
    }
}
