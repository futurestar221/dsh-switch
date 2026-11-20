# Third-party notices

## Microsoft WebView2 SDK

- Package: `Microsoft.Web.WebView2`
- Version used by the build: `1.0.2903.40`
- Purpose: WinForms desktop wrapper
- License and redistribution terms: https://learn.microsoft.com/microsoft-edge/webview2/

The build script restores the SDK from NuGet. Release packages may include the following redistributable files:

- `Microsoft.Web.WebView2.Core.dll`
- `Microsoft.Web.WebView2.WinForms.dll`
- `WebView2Loader.dll`

## Microsoft .NET Framework 4.8

The application targets .NET Framework 4.8. The runtime is a Microsoft system component and is not modified by this project.

## Other components

The project does not bundle third-party JavaScript frameworks, fonts, analytics SDKs or CDN assets. The UI uses only local HTML/CSS/JavaScript and Windows system components.