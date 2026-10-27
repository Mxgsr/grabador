import ArgumentParser
import CoreGraphics

/// Permiso de "Grabación de pantalla y audio del sistema". Cuando corres el CLI desde
/// Terminal, macOS se lo asigna a Terminal (no al binario `grabador`).
enum Permisos {
    static func tieneGrabacionDePantalla() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Muestra el aviso del sistema la primera vez; después solo se cambia en Ajustes.
    @discardableResult
    static func pedir() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func explicar() {
        print("""
        ✋ Falta el permiso de grabación de pantalla y audio del sistema.
           1. Abre Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema.
           2. Activa Terminal (o la app desde la que corres grabador).
           3. Cierra Terminal por completo (Cmd+Q) y vuelve a abrirla: macOS solo aplica el permiso al reiniciarla.
           La primera grabación también pedirá permiso de Micrófono para Terminal: acéptalo.
        """)
    }
}

/// `grabador permiso`: revisa el permiso y, si falta, abre el aviso de macOS.
struct Permiso: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Revisa o pide el permiso de grabación de pantalla y audio del sistema."
    )

    func run() throws {
        if Permisos.tieneGrabacionDePantalla() {
            print("✅ El permiso de grabación está activo.")
            return
        }
        Permisos.pedir()
        Permisos.explicar()
    }
}
