/// Moves a path saved by an earlier install of the app into the current
/// container. iOS gives the app's container a new name when the app is
/// reinstalled or updated, and what is saved under the old one, such as an
/// unfinished file transfer, would point nowhere.
///
/// [home] is any path inside the current container's Documents folder.
String rebaseIosContainerPath(String path, String home) {
  const marker = '/Documents/';
  final at = path.indexOf(marker);
  final homeAt = '$home/'.indexOf(marker);
  if (at < 0 || homeAt < 0) return path;
  return home.substring(0, homeAt) + path.substring(at);
}
