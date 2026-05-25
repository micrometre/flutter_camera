# 1FPS Camera

A Flutter camera application for capturing low-FPS timelapse video streams. The app specializes in 1 FPS recording for extended duration capture with minimal storage usage.

## Features

- **1 FPS Recording**: Specialized in 1 FPS timelapse capture for extended duration recording
- **Configurable FPS**: Adjustable frame rates from 1-30 FPS for different timelapse effects
- **Adjustable Bitrate**: Set video bitrate between 0.5-10 Mbps for quality/size optimization
- **Preview Engine Modes**:
  - Live preview: Smooth real-time camera feed
  - 1-FPS Preview: 1 FPS snapshot stream view matching recording rate
- **Pause/Resume Recording**: Pause and resume recording without stopping the session
- **Playback**: Review captured timelapse sequences before exporting
- **Auto-Export**: Videos are automatically saved to the device Downloads folder
- **Share Functionality**: Share videos directly from the app
- **Camera Switching**: Toggle between front and back cameras (if available)

## Requirements

- Flutter SDK
- Android 5.0+ or iOS 10.0+
- Camera permission
- Storage permission (for saving videos to Downloads folder)

## Installation

1. Clone the repository
2. Install dependencies:
   ```bash
   flutter pub get
   ```
3. Run the app:
   ```bash
   flutter run
   ```

## Permissions

The app requires the following permissions:
- **Camera**: To access the device camera for recording
- **Storage**: To save exported videos to the Downloads folder (Android)

## Usage

### Recording

1. Tap the **RECORD** button to start capturing frames
2. Use the **PAUSE** button to pause/resume recording
3. Tap **STOP** to end the recording session

### Settings

Tap the **SETTINGS** button at the bottom to adjust:
- **FPS**: Frame rate (1-30 FPS) - use 1 FPS for extended timelapse recording, higher values for smoother playback
- **Bitrate**: Video quality (0.5-10 Mbps) - higher values produce larger, better quality videos
- **Preview Engine**: Switch between Live and 1-FPS preview modes

### Playback

1. After recording, tap **PLAY TIMELAPSE** to preview the captured sequence
2. Tap **STOP PREV** to exit playback mode

### Export

1. Tap **EXPORT SEQUENCE** to compile frames into an MP4 video
2. The video is automatically saved to the Downloads folder as `timelapse_[timestamp].mp4`
3. A share dialog appears to easily share the video

## Technical Details

- **Video Encoding**: Uses `flutter_quick_video_encoder` for efficient video compilation
- **Resolution**: Medium resolution preset (balanced quality/performance)
- **Output Format**: MP4 (H.264)
- **Frame Format**: Raw RGBA for encoding compatibility

## Dependencies

- `camera`: ^0.12.0+1 - Camera access and control
- `path_provider`: ^2.1.5 - Access to device directories
- `share_plus`: ^13.1.0 - Share functionality
- `flutter_quick_video_encoder`: ^1.7.2 - Video encoding
- `image`: ^4.8.0 - Image processing
- `permission_handler`: ^11.3.1 - Permission management

## License

This project is part of the 1FPS Camera application.
