# MasqFit 1.1.0 release candidate

- App version: 1.1.0; initial build: 2.
- App tag: `v1.1.0-rc.1`.
- Companion BreatheSafe tag: `masqfit-api-v1.1.0-rc.1`.
- PRs: [MasqFit #3](https://github.com/Edderic/masqfit/pull/3), [BreatheSafe #23](https://github.com/Edderic/breathesafe/pull/23).

The tags identify source candidates, not an App Store approval or backend deployment. Do not move published tags; use rc.2 for further candidate changes. Create final tags after validation. Confirm the version/build is unused in App Store Connect; its existing build history has not been inspected. Xcode can manage upload build numbers if build 2 is already taken.

## What is included

Anonymous contribution and measure-only flows, saved-measurement reuse across visits, MFTC batch selection and privacy review, and admin-assisted mask matching. Batch review defaults to N99-mode and explicitly asks users to confirm it; N95 and Unknown remain available. Scores do not automatically determine the mode. Raw QR decoding and existing queued payloads retain their prior behavior.

## Release order

1. Merge the backend PR after CI passes. Deploy the backend candidate through the established production pipeline and verify migration `20260929010000` is applied. Verify the measurement lookup and admin matching screens; do not assume a Git tag deployed the backend.
2. Merge the app PR. Test on a TrueDepth iPhone: fresh participant, saved-code measurement reuse, mixed-participant QR selection, privacy edits, default N99 and changing to N95/Unknown, admin matching after submission, and offline queue recovery.
3. Archive/upload the exact candidate and use TestFlight before App Review. Confirm App Store privacy disclosures and privacy policy reflect uploaded measurements, fit-test results, and the reusable participant code. Uploaded data is linked across visits, even without a name/email.

## Manual upload from Xcode

Open `MasqFit.xcodeproj` from the release candidate checkout (not an older working branch). The checked-in shared **MasqFit** scheme archives with **Release** configuration.

1. In Xcode Settings → Accounts, sign in with your Apple Developer account and accept any pending developer agreements. In Signing & Capabilities, select your paid developer team and automatic signing. Keep bundle ID `xyz.breathesafe.masqfit`.
2. Select the MasqFit scheme and a generic iOS device destination such as **Any iOS Device (arm64)**. Choose **Product → Archive**.
3. In **Window → Organizer → Archives**, select the archive and choose **Distribute App → App Store Connect**, then upload using the App Store distribution flow. Let Xcode manage the build number if necessary. An unsigned command-line validation build is not uploadable.
4. Wait for processing in App Store Connect. Test the uploaded build in TestFlight. Create/select App Store version **1.1.0**, choose the build, complete required metadata, screenshots, privacy details, and reviewer instructions, then submit for review.
5. Choose **Manually release this version** if you want control over when the approved update becomes public. Uploading a build alone does not publish it.

Apple references: [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds), [Submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app), [Release options](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/).

## Automated build/upload with Xcode Cloud

The shared scheme is committed, so the project can be configured for Xcode Cloud. In Xcode, start an Xcode Cloud workflow, connect the `Edderic/masqfit` GitHub repository, and select the MasqFit scheme. Configure an iOS Archive action with distribution for TestFlight/App Store and an internal TestFlight distribution post-action. Start with manual runs against the release branch; after verification, enable runs for your chosen release branch or tag condition.

Apple hosts the build and signing workflow, avoiding signing-certificate exports into GitHub secrets. The initial Apple/GitHub connection, team selection, and workflow setup require your account access; they are not configured by this PR. App Review submission and public release remain separate steps. See [Configure Xcode Cloud](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow) and [TestFlight distribution](https://developer.apple.com/documentation/xcode/distributing-your-xcode-cloud-builds-through-testflight).

## Suggested release notes

- Contribute facial measurements without creating an account.
- Reuse saved measurements for later fit tests.
- Import and review community fit tests in batches.
- Choose N99, N95, or Unknown testing mode.
- Let admins review mask matches with automated suggestions.

## Candidate validation

The 1.1.0 build 2 candidate passed 199 standalone Swift checks and a full generic-iOS Release build with `CODE_SIGNING_ALLOWED=NO` on Xcode 26.6. This verifies compilation/resources, not signing or App Store validation. A signed archive, device/TestFlight checks, and upload are still required.
