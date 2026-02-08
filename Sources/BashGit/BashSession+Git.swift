import BashSwift

public extension BashSession {
    func registerGit() async {
        await register(GitCommand.self)
    }
}
