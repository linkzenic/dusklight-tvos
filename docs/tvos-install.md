# Installing the unsigned tvOS build

Dusklight's public Apple TV download is an unsigned IPA. It contains no Apple certificate,
provisioning profile, development-team identifier, or registered device information.

## Requirements

- An Apple TV with Developer Mode enabled
- A Mac with Xcode, or another tvOS-compatible signing tool
- Your own Apple ID or Apple Developer account
- Your own legally dumped supported GameCube disc image

## Sign and install

Sign `Dusklight-tvos-unsigned.ipa` with your own Apple account and a bundle identifier registered
to your Apple development team. Free Apple IDs generally require frequent re-signing; paid Apple
Developer accounts allow longer-lived development installations.

The repository does not distribute signing profiles or certificates. Do not reuse another
developer's provisioning profile: it will not authorize your Apple TV or your signing identity.

## Transfer the game

1. Launch Dusklight on Apple TV.
2. Select **Transfer Game Disc**.
3. Open the displayed `http://` address on a phone or computer on the same local network.
4. Choose your supported disc image and upload it.
5. Keep Dusklight open while the disc is verified.

The disc image remains in Dusklight's private Apple TV app container.

## Texture replacements

In Dusklight's rendering settings, enable texture replacements and start the Apple TV texture
transfer. Upload one ZIP archive containing the replacement texture hierarchy. Dusklight safely
extracts the ZIP into its private texture-replacement directory.

## iCloud saves

CloudKit entitlements cannot be shared by arbitrary personal signatures. To build with iCloud
save sync, create a CloudKit container owned by your Apple development team and configure with:

```sh
cmake -S . -B build/tvos \
  -DDUSK_APPLE_CODE_SIGNING=ON \
  -DDUSK_ICLOUD_CONTAINER_ID=iCloud.your.bundle.container \
  -DDUSK_ICLOUD_CONTAINER_ENVIRONMENT=Development
```

Then sign the generated app with your own compatible entitlement and provisioning profile.
Unsigned public artifacts do not include a usable CloudKit entitlement.

## Quit behavior

Press the TV/Home button to leave Dusklight. To terminate it completely, open the tvOS app
switcher, highlight Dusklight, and swipe up. tvOS apps should not terminate themselves.
