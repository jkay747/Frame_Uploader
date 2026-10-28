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

1. Find your TV's IP address. On the TV, go to **Settings › All Settings › General & Privacy › Network › Network Status › IP Settings**. Menu names vary a little by model year. Reserving that address in your router stops it from changing later.
2. In the app, open **Settings** (⌘,) › **TV**, enter the address, and click **Connect & Pair**.
3. The TV asks whether to allow "Frame Uploader". Choose **Allow** with the remote. The app remembers the pairing.
4. macOS may ask to let the app find devices on your local network. Click **Allow**.

## Using it

1. Drop folders onto the window, or click **Add Folder** / **Add Photos Album** in the toolbar.
2. Check the previews. Click a photo to leave it out, or right-click for more options.
3. Click **Upload**. Each photo shows a check mark when it's done. A summary appears at the end.

The mat style, mat color and slideshow options are under **Settings › Art Mode**. The upload history is under **Settings › Uploads**.

## Troubleshooting

| Problem | Try this |
| --- | --- |
| "No TV answered" | Make sure the TV is on or in Art Mode (not fully off), and that the Mac is on the same Wi-Fi/network. Check the IP address. |
| The TV refused the connection | Click **Forget Pairing**, then **Connect & Pair**, and choose **Allow** on the TV. On the TV you can also check **Settings › General › External Device Manager › Device Connection Manager**. |
| The mat isn't accepted | Some mat/color combinations aren't available on every model. The app uploads without a mat and says so. |
| The local network prompt was denied | **System Settings › Privacy & Security › Local Network**, then turn on Frame Uploader. |
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
