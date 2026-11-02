import Foundation

// Wait for an application's accessibility tree without blocking the main
// run loop or following the user into a different window during preparation.
enum InputFocusPreparation {
    static func capture<T>(isCurrent: @escaping () -> Bool,
                           read: @escaping () throws -> T,
                           prepare: () -> Bool,
                           retryCount: Int = 50, interval: TimeInterval = 0.05,
                           completion: @escaping (Result<T, Error>) -> Void) {
        func changed() -> DirectInputError { .message("输入焦点已改变，请重新点选目标输入框后重试") }
        guard isCurrent() else { completion(.failure(changed())); return }
        do { completion(.success(try read())); return }
        catch {
            guard prepare() else { completion(.failure(error)); return }
        }
        func retry(_ remaining: Int) {
            guard isCurrent() else { completion(.failure(changed())); return }
            do { completion(.success(try read())) }
            catch {
                guard remaining > 0 else { completion(.failure(error)); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + interval) { retry(remaining - 1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { retry(max(0, retryCount - 1)) }
    }
}
