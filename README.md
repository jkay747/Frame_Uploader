# Frame Uploader

A Mac app that sends folders of photos, or Apple Photos albums, to a Samsung Frame TV (2022 or newer). Every photo is reshaped to the TV's 16:9 screen (3840×2160) before it's uploaded:

- **Landscape photos** are cropped to fill the screen. The crop centers on faces when there are any, otherwise on the main subject (found with Apple's Vision framework).
- **Portrait and square photos** are shown whole on a soft, blurred copy of themselves, so nothing gets cut off.

The window shows a preview of exactly what the TV will display before you upload.

## Features

- Drag folders, or individual photos, onto the window. Subfolders are included.
- Add albums straight from Apple Photos, including Favorites and shared albums.
- Reads JPEG, PNG, HEIC (iPhone), TIFF, RAW and other formats macOS understands. Everything is converted to JPEG for the TV.
- **Skip duplicates:** photos already on the TV are recognized by their content, even if renamed or moved, and aren't uploaded again.
- **Replace previous upload:** after uploading, removes photos *this app* uploaded earlier that aren't in the new batch. Photos you added to the TV any other way are never touched.
- **Mats:** pick any of the TV's mat styles and colors, or none for edge-to-edge.
- **Sized for 4K:** each photo is decoded only at the resolution the 3840×2160 output needs and saved as an sRGB JPEG, usually 1–3 MB. The next photo is prepared while the current one uploads.
- **Slideshow:** optionally starts the Art Mode slideshow (shuffled or in order) when the upload finishes.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later (free from the Mac App Store)
- A Samsung Frame TV from 2022 or later, on the same network as your Mac

## Build and run

1. Open `FrameUploader.xcodeproj` in Xcode.
2. Choose **Product › Run** (⌘R).

No Apple developer account is needed. The app is signed to run on your own Mac. To keep a copy outside Xcode, choose **Product › Archive**, then **Distribute App › Copy App**, and drag `Frame Uploader.app` into Applications.

## First-time setup

1. Turn the TV on (Art Mode is fine) and launch the app. It searches your network for Frame TVs automatically. macOS will ask to let the app find devices on your local network; click **Allow**.
2. Choose your TV from the list. If none is found, the app shows how to look up the TV's IP address, and you can type it in:

   > Press the Home button on your Samsung remote.
   >
   > 1. Go to Settings.
   > 2. Select General (or Connection / System depending on your Tizen year).
   > 3. Choose Network or Device Name.

3. On your first upload, or when you click **Settings › TV › Connect & Pair**, the TV asks whether to allow "Frame Uploader". Choose **Allow** with the remote. The app remembers the pairing.

If the TV later gets a new IP address from your router, the app finds it again on its own and keeps the pairing and upload history.

## Using it

1. Drop folders onto the window, or click **Add Folder** / **Add Photos Album** in the toolbar.
2. Check the previews. Click a photo to leave it out, or right-click for more options.
3. Click **Upload**. Each photo shows a check mark when it's done. A summary appears at the end.

The mat style, mat color and slideshow options are under **Settings › Art Mode**. The upload history is under **Settings › Uploads**.

## Local network access

macOS 15 and later ask before an app may talk to devices on your home network. If Frame Uploader can't reach the TV, the app now says so. In Xcode's log it shows up as `Local network prohibited`, often next to a misleading "The Internet connection appears to be offline".

1. Open **System Settings › Privacy & Security › Local Network** and turn on **Frame Uploader**.
2. Quit and reopen the app.

If the switch is already on, or the app isn't listed, macOS may be confused by rebuilt copies of the app. By default the project is signed "to run locally", which gives every build a slightly different identity. Signing with your free Apple ID makes the identity stable:

1. In Xcode, select the **FrameUploader** project, then the **FrameUploader** target, then **Signing & Capabilities**.
2. Turn on **Automatically manage signing**, and choose your **Personal Team** (add your Apple ID under Xcode › Settings › Accounts if it isn't listed).
3. Build and run again. Allow the local network prompt when it appears.

As a last resort, turning the Local Network switch off and on, or restarting the Mac, clears a stuck permission.

## Troubleshooting

| Problem | Try this |
| --- | --- |
| Xcode's log is full of messages | Most are harmless macOS noise: `linkd.autoShortcut`, `Accessibility: Not vending elements`, `ViewBridge`, `CMPhotoDecompressionContainer`, `fopen failed`, `com.apple.accounts`, and `tcp_input … [R]`, which is the TV closing a finished transfer. Lines worth reporting mention `Local network prohibited` or come from `FrameUploader` itself. |
| "No TV answered" | Make sure the TV is on or in Art Mode (not fully off), and that the Mac is on the same Wi-Fi/network. Check the IP address. |
| The TV refused the connection | Click **Forget Pairing**, then **Connect & Pair**, and choose **Allow** on the TV. On the TV you can also check **Settings › General › External Device Manager › Device Connection Manager**. |
| The mat isn't accepted | Some mat/color combinations aren't available on every model. The app uploads without a mat and says so. |
| Some photos didn't upload | Each one is marked with an orange warning and the reason under its name, and the end-of-upload summary lists them. Click **Retry Failed** to send just those (earlier uploads are left alone). If the connection drops mid-batch, the app reconnects on its own, up to five times. |
| Uploads are slow | Open the **Console** app, search for `FrameUploader`, and upload a few photos. Each one logs how long preparing, the transfer, and the TV's own processing took. The summary at the end shows the average time per photo. |
| "macOS is blocking access to your local network" | See **Local network access** above. |
| Photos access was denied | **System Settings › Privacy & Security › Photos**, then turn on Frame Uploader. |

Because the app is signed locally, macOS may ask for Photos or local network permission again after you rebuild it in Xcode.

## How it works

| Folder | What's there |
| --- | --- |
| `FrameUploader/TV` | Art Mode protocol: a websocket to `wss://<tv>:8002/api/v2/channels/com.samsung.art-app` for commands, plus the TCP socket the TV opens for each image transfer. |
| `FrameUploader/Imaging` | Subject detection (Vision), crop geometry, blurred-fill rendering, JPEG encoding. |
| `FrameUploader/Library` | Folder scanning and Apple Photos (PhotoKit) access. |
| `FrameUploader/Upload` | Upload flow, duplicate/replace bookkeeping, preview generation. |
| `FrameUploader/Views` | SwiftUI windows and settings. |

The upload history lives in `~/Library/Application Support/FrameUploader/uploads.json`.

The Art Mode protocol isn't documented by Samsung. This implementation follows the open-source [samsung-tv-ws-api](https://github.com/xchwarze/samsung-tv-ws-api) project.
