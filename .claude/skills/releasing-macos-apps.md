# Releasing macOS Apps

Complete workflow for releasing AgentHub.

## Prerequisites

- Apple Developer account
- Developer ID Application certificate
- Sparkle framework integrated
- EdDSA key pair for Sparkle

## Release Workflow

### Phase 1: Version Update

1. Update version in Xcode project
   - Marketing Version (e.g., 1.2.0)
   - Current Project Version (build number)

2. Update CHANGELOG if applicable

### Phase 2: Build Archive

```bash
xcodebuild -project app/AgentHub.xcodeproj \
  -scheme AgentHub \
  -configuration Release \
  -archivePath build/AgentHub.xcarchive \
  archive
```

### Phase 3: Export and Sign

```bash
xcodebuild -exportArchive \
  -archivePath build/AgentHub.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist app/ExportOptions.plist
```

### Phase 4: Notarization

```bash
# Submit for notarization
xcrun notarytool submit build/export/AgentHub.app \
  --apple-id "your@email.com" \
  --team-id "TEAMID" \
  --password "@keychain:AC_PASSWORD" \
  --wait

# Staple the ticket
xcrun stapler staple build/export/AgentHub.app
```

### Phase 5: Create DMG

```bash
# Create DMG with drag-to-Applications
./scripts/build-dmg.sh
```

### Phase 6: Sparkle Signature

```bash
# Generate EdDSA signature for appcast
./bin/sign_update build/AgentHub-1.2.0.dmg

# Output: sparkle:edSignature="..." length="..."
```

### Phase 7: Update Appcast

Edit `appcast.xml`:
```xml
<item>
  <title>Version 1.2.0</title>
  <sparkle:version>123</sparkle:version>
  <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
  <pubDate>Mon, 01 Jan 2024 12:00:00 +0000</pubDate>
  <enclosure
    url="https://github.com/.../AgentHub-1.2.0.dmg"
    sparkle:edSignature="..."
    length="12345678"
    type="application/octet-stream"/>
</item>
```

### Phase 8: GitHub Release

1. Create git tag
```bash
git tag -a v1.2.0 -m "Release 1.2.0"
git push origin v1.2.0
```

2. Create GitHub release
3. Upload DMG as release asset
4. Update appcast.xml URL if needed

### Phase 9: Verification

1. Download DMG from GitHub
2. Verify signature: `spctl -a -v AgentHub.app`
3. Test auto-update from previous version
4. Verify appcast is accessible

## Troubleshooting

### Notarization Failed
- Check entitlements
- Ensure hardened runtime
- Check for unsigned frameworks

### Sparkle Update Failed
- Verify EdDSA signature
- Check appcast URL accessibility
- Verify version numbers

### Code Signing Issues
- Check certificate validity
- Ensure correct team selected
- Re-download certificates if needed

## Checklist

- [ ] Version updated
- [ ] Archive created
- [ ] Signed with Developer ID
- [ ] Notarized and stapled
- [ ] DMG created
- [ ] Sparkle signature generated
- [ ] Appcast updated
- [ ] Git tagged
- [ ] GitHub release created
- [ ] DMG uploaded
- [ ] Auto-update tested
