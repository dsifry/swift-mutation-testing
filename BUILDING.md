# Building Swift Mutation Testing

This guide explains how to build, test, and run `swift-mutation-testing` from a local checkout.

## Prerequisites

- macOS 15 or later
- Xcode 16 or later
- Swift 6.2 or later
- Git

Verify the Swift toolchain before building:

```bash
swift --version
```

The package uses Swift Package Manager. No manual dependency installation is required; SPM resolves the `swift-syntax` dependency during build and test commands.

## Clone the repository

```bash
git clone https://github.com/ericodx/swift-mutation-testing.git
cd swift-mutation-testing
```

## Build

For day-to-day development, build the debug configuration:

```bash
swift build
```

For a local release binary, build with optimizations:

```bash
swift build -c release
```

The release executable is written to:

```text
.build/release/swift-mutation-testing
```

## Run tests

Run the full Swift Package Manager test suite:

```bash
swift test
```

The test suite includes unit tests and integration-tagged coverage for the fixture projects. If a local toolchain or simulator setup is incomplete, fix that environment issue before relying on the result.

## Run locally

Run the command directly from the checkout without installing it globally:

```bash
swift run swift-mutation-testing --help
swift run swift-mutation-testing --version
```

You can also point the local checkout at another Swift project:

```bash
swift run swift-mutation-testing /path/to/project
```

For Xcode projects, provide the scheme and destination used by that project:

```bash
swift run swift-mutation-testing /path/to/project \
  --scheme MyApp \
  --destination "platform=macOS"
```

## Install the local build

After building the release configuration, copy the executable into a directory on your `PATH`:

```bash
sudo cp .build/release/swift-mutation-testing /usr/local/bin/
```

Verify the installed command:

```bash
swift-mutation-testing --version
swift-mutation-testing --help
```

To remove the manually installed binary:

```bash
sudo rm /usr/local/bin/swift-mutation-testing
```
