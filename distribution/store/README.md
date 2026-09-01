# Microsoft Store release input

The app release workflow gets the reserved Partner Center identity from the
protected `app-release` GitHub environment. No placeholder identity may be
used for a public package.

Required environment variables/secrets:

- `STORE_IDENTITY_NAME`, `STORE_PACKAGE_FAMILY_NAME`, `STORE_PUBLISHER`,
  `STORE_PUBLISHER_DISPLAY_NAME`
- `STORE_PRODUCT_ID`
- `STORE_TENANT_ID`, `STORE_SELLER_ID`, `STORE_CLIENT_ID`, `STORE_CLIENT_SECRET`

Partner Center must approve both `runFullTrust` and
`unvirtualizedResources`. A successful workflow submission means submitted
for certification, not certified or live. The workflow retains submission
output so those states can be reported separately.

The initial free listing and reserved product are external onboarding steps.
Subsequent updates submit the exact signed MSIX already verified and attached
to the GitHub Release; they do not rebuild it.
