# Revenue Dashboard

App SwiftUI (iOS y macOS) que junta en un único panel, y en euros, lo que ganas con tus apps:

- **Apple App Store Connect**: suscripciones, compras in-app y apps de pago (proceeds netos, informes diarios de ventas).
- **Google AdMob**: ingresos por publicidad (bruto estimado).
- **Firebase / Google Analytics 4**: pestaña «Uso» con usuarios activos, sesiones y eventos por app.

Convierte todas las divisas a EUR con el tipo de cambio diario del BCE.

<p align="center"><img src="docs/dashboard.png" width="420" alt="Panel de ingresos (datos de demostración)"></p>

> La captura usa datos de relleno (`-demo`), no cifras reales.

## Características

- Periodos de 7 d, 30 d, 90 d, 6 m y 1 año; la elección se recuerda entre sesiones.
- Gráfico por día apilado por origen (publicidad / in-app / suscripciones) y desglose por app.
- Indica hasta qué día tiene datos cada proveedor.
- Caché en disco de los informes cerrados de Apple y del tipo de cambio.
- Credenciales en el Keychain; nada se envía a servidores de terceros salvo Apple, Google y el BCE.

## Estructura

| Carpeta | Contenido |
|---|---|
| `Sources/RevenueKit` | Clientes de ASC, AdMob y GA4, parser de informes, conversión BCE, Keychain |
| `App` | Interfaz SwiftUI |
| `Sources/RevenueProbe` | Herramienta de línea de comandos para depurar los datos de Apple |
| `Tests` | Tests con Swift Testing |

## Puesta en marcha

Requisitos: Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

1. Copia la configuración local (está en `.gitignore`):
   ```bash
   cp Config/Local.example.xcconfig Config/Local.xcconfig
   ```
   y rellena tu bundle ID, tu Team ID y el client ID de Google (paso 3).
2. Genera el proyecto y ábrelo:
   ```bash
   xcodegen generate && open RevenueDashboard.xcodeproj
   ```
3. **Google (AdMob y Analytics)**: en [Google Cloud Console](https://console.cloud.google.com) crea un cliente OAuth de tipo **iOS** con tu bundle ID y activa las APIs *AdMob*, *Analytics Admin* y *Analytics Data*. Pega su client ID en `GOOGLE_CLIENT_ID`. Usa PKCE, no hay client secret.
4. **Apple**: en App Store Connect → Usuarios y acceso → Integraciones, crea una clave de API con acceso a **Ventas** (o Finanzas). En la app, Ajustes → introduce Issuer ID, Key ID, tu *vendor number* (Ventas y tendencias → Informes) e importa la clave `.p8`.

Para ver el diseño sin credenciales, arranca la app con el argumento `-demo`.

## Notas

- Los informes de Apple se publican con 1-2 días de retraso; AdMob puede revisar importes recientes.
- Las ventas de Apple usan *Developer Proceeds* (tras comisión e impuestos), por eso difieren del importe de venta.
- El importe en EUR puede diferir ligeramente de lo que ves en Tendencias de App Store Connect, que muestra la divisa original (p. ej. USD).
