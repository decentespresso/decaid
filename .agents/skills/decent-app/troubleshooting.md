# Runtime troubleshooting

## macOS and iOS Swift Package Manager clones

Flutter's Apple build can report that no `firebase-ios-sdk` version satisfies a valid constraint when a project-local Swift Package Manager clone is stale. Confirm whether the cached repository is missing the required tag:

```bash
git --git-dir=build/macos/SourcePackages/repositories/firebase-ios-sdk-* \
  tag | grep '^12\.' | tail
```

If it is stale, remove only the generated project-local package clones and rebuild:

```bash
rm -rf build/macos/SourcePackages build/ios/SourcePackages
flutter build macos --debug
```

Do not disable Swift Package Manager. The current Flutter pin is authoritative in `.github/workflows/develop-builds.yml`; do not copy its exact version into this skill.
