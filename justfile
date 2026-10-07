# Run xcodebuild in a clean env: Devbox/Nix injects SDKROOT, CC and compiler flags that
# break Xcode builds. Also forces full Xcode instead of Command Line Tools.
xcodebuild := "env -i HOME=\"$HOME\" PATH=/usr/bin:/bin:/usr/sbin:/sbin DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild"

app := "volumeHUD.app"
bundle_id := "com.dannystewart.volumehud"
derived_data := "build"
release_app := derived_data / "Build/Products/Release" / app
install_dir := "/Applications"

default:
    @just --list

# Build a Release app, ad-hoc signed for local use
build:
    {{xcodebuild}} -project volumeHUD.xcodeproj -scheme volumeHUD -configuration Release \
        -derivedDataPath {{derived_data}} \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
        build -quiet

# Build, replace the installed app, reset permissions, and relaunch
install: build
    -pkill -f "{{install_dir}}/{{app}}"
    rm -rf "{{install_dir}}/{{app}}"
    cp -R "{{release_app}}" "{{install_dir}}/"
    -tccutil reset Accessibility {{bundle_id}}
    -tccutil reset ListenEvent {{bundle_id}}
    open "{{install_dir}}/{{app}}"
    @echo "Grant Accessibility in System Settings → Privacy & Security → Accessibility."

# Format and lint Swift sources
lint:
    swiftformat --config .swiftformat volumeHUD
    swiftlint lint volumeHUD

# Remove local build output
clean:
    rm -rf {{derived_data}}
