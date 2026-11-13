# Releasing

Two packages are published to pub.dev from this repository: `halvorai_ingest` and `halvorai_ingest_flutter`. Publish `halvorai_ingest` first, because the Flutter package depends on it.

A version on pub.dev can't be deleted. It can be retracted for seven days after it is published.

## The first release, by hand

pub.dev only automates publishing for a package that already exists, so the first version of each package is published from a developer's machine.

1. Sign in to pub.dev with the Google account that will own the packages. A verified publisher for `halvorai.com` keeps ownership with the company instead of one person; packages can be moved to it afterwards.
2. From an up-to-date `main`, with CI green:

   ```bash
   flutter pub get
   (cd packages/halvorai_ingest && dart test && flutter pub publish)
   (cd packages/halvorai_ingest_flutter && flutter test && flutter pub publish)
   ```

3. Tag what was published, so the tags and versions stay in step:

   ```bash
   git tag halvorai_ingest-v0.1.0-dev.2
   git tag halvorai_ingest_flutter-v0.1.0-dev.2
   git push origin halvorai_ingest-v0.1.0-dev.2 halvorai_ingest_flutter-v0.1.0-dev.2
   ```

   The publish workflow starts for each tag, sees the version is already on pub.dev, and stops without publishing.

4. On each package's **Admin** tab on pub.dev, enable **Automated publishing** from GitHub Actions:

   | Package | Repository | Tag pattern | Environment |
   | --- | --- | --- | --- |
   | `halvorai_ingest` | `halvorAI/ingest-dart` | `halvorai_ingest-v{{version}}` | `pub.dev` |
   | `halvorai_ingest_flutter` | `halvorAI/ingest-dart` | `halvorai_ingest_flutter-v{{version}}` | `pub.dev` |

   Requiring the `pub.dev` environment means a release can be gated on reviewers in this repository's environment settings.

## Later releases

1. Bump `version` in the package's `pubspec.yaml`. For `halvorai_ingest`, bump `lib/src/version.dart` too; a test keeps the two in step. If the Flutter package needs the new core version, raise its `halvorai_ingest` constraint.
2. Add the version to the package's `CHANGELOG.md`.
3. Merge to `main` and wait for CI.
4. Push a tag, or create a GitHub release with that tag. `.github/workflows/publish.yml` checks the tag against `pubspec.yaml`, runs the tests and publishes.

   ```bash
   git tag halvorai_ingest-v0.1.0
   git push origin halvorai_ingest-v0.1.0
   ```

When both packages change, release `halvorai_ingest` first and wait for it to appear on pub.dev before tagging `halvorai_ingest_flutter`.
