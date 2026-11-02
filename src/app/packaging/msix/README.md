# MSIX package inputs

The shared `package-user` GitHub action renders `AppxManifest.xml.in` and packs an
explicit app executable. It uses the committed `Assets` PNGs without resampling
them during package builds. Keep their transparent background and dimensions.

To regenerate the assets after changing the universal source logo, run these
ImageMagick commands from the repository root, then inspect and commit the PNGs:

```powershell
magick src/app/frontend/src/assets/images/logo-universal.png -resize '50x50!' src/app/packaging/msix/Assets/StoreLogo.png
magick src/app/frontend/src/assets/images/logo-universal.png -resize '44x44!' src/app/packaging/msix/Assets/Square44x44Logo.png
magick src/app/frontend/src/assets/images/logo-universal.png -resize '150x150!' src/app/packaging/msix/Assets/Square150x150Logo.png
magick src/app/frontend/src/assets/images/logo-universal.png -resize '310x150!' src/app/packaging/msix/Assets/Wide310x150Logo.png
```

ImageMagick is only an asset-maintenance tool. Packaging requires the prepared
Windows SDK and NSIS executables on PATH, not ImageMagick or Visual Studio Appx
projects. `act -P windows-latest=-self-hosted` builds files on the host and provides
no installation isolation; use the selected Just workflow wrapper for local runs.
