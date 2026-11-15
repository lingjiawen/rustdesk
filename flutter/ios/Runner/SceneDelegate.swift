import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  // A short grace period keeps a remote session alive across a quick trip to
  // another app, such as copying a code from Messages. iOS suspends the app
  // once it runs out.
  func sceneDidEnterBackground(_ scene: UIScene) {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "RustDeskSession") {
      [weak self] in
      self?.endBackgroundTask()
    }
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    endBackgroundTask()
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    (UIApplication.shared.delegate as? AppDelegate)?.sceneWillConnect(
      window: window, launchURL: connectionOptions.urlContexts.first?.url)
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
    for context in URLContexts {
      _ = appDelegate.application(UIApplication.shared, open: context.url, options: [:])
    }
  }
}
