import Foundation

/// Décodeur des rapports HID *vendor-defined* envoyés par les tablettes
/// Wacom Intuos 5 / Intuos Pro (dont la PTH-451).
///
/// Format de référence : `drivers/hid/wacom_wac.c`, fonctions `wacom_intuos_irq`,
/// `wacom_intuos_inout`, `wacom_intuos_general` du noyau Linux.
///
/// Toutes les valeurs `data[i]` sont des octets ; les indices sont relatifs au
/// début du rapport, RID inclus (data[0] = report ID).
enum IntuosProParser {

    /// Résultat du décodage d'un rapport pen.
    enum Result {
        case proximityEnter(toolID: UInt32, serial: UInt64)
        case proximityLeave
        case pen(PenSample)
        case ignored
    }

    /// Échantillon pen complet — coordonnées + pression + tilt + boutons.
    struct PenSample {
        var x: Int
        var y: Int
        var pressure: Int      // 0..2047
        var distance: Int      // 0..63
        var tiltX: Int         // -64..63
        var tiltY: Int         // -64..63
        var tipDown: Bool
        var barrelButton1: Bool
        var barrelButton2: Bool
        var eraser: Bool
    }

    /// Tente de décoder un rapport. Retourne `.ignored` si le rapport ne nous
    /// concerne pas (rapport pad, statut batterie, etc.).
    static func decode(reportID: UInt32, data: UnsafeMutablePointer<UInt8>, length: Int) -> Result {
        // Le rapport pen est l'ID 0x02 et fait 10 octets.
        guard reportID == 2, length >= 10 else { return .ignored }

        let d = data
        let status = d[1]

        // ---- Détection proximité enter/leave -----------------------------
        //
        // Linux : `(data[1] & 0xfc) == 0xc0` → entrée en proximité.
        // Linux : `(data[1] & 0xfe) == 0x80` → sortie de proximité.
        if (status & 0xfe) == 0x80 {
            return .proximityLeave
        }
        if (status & 0xfc) == 0xc0 {
            // Rapport "tool ID" — donne le numéro de série du stylet.
            let toolID: UInt32 =
                (UInt32(d[2]) << 4) |
                (UInt32(d[3]) >> 4) |
                (UInt32(d[7] & 0x0f) << 16) |
                (UInt32(d[8] & 0xf0) << 8)
            let serial: UInt64 =
                (UInt64(d[3] & 0x0f) << 28) |
                (UInt64(d[4]) << 20) |
                (UInt64(d[5]) << 12) |
                (UInt64(d[6]) << 4)  |
                (UInt64(d[7]) >> 4)
            return .proximityEnter(toolID: toolID, serial: serial)
        }

        // ---- Rapport pen "général" (en proximité, avec ou sans contact) --
        //
        // Linux teste `(data[1] & 0xb8) == 0xa0` pour les paquets contenant
        // position/pression/tilt. Bits restants de `data[1]` :
        //   bit 0 → LSB de la pression (extension 11 bits)
        //   bit 1 → barrel switch 1
        //   bit 2 → barrel switch 2 (rarement utilisé sur Grip Pen)
        //   bit 3 → tip switch / eraser
        guard (status & 0xb8) == 0xa0 else { return .ignored }

        let x: Int =
            (Int(d[2]) << 9) |
            (Int(d[3]) << 1) |
            ((Int(d[9]) >> 1) & 1)

        let y: Int =
            (Int(d[4]) << 9) |
            (Int(d[5]) << 1) |
            (Int(d[9]) & 1)

        let rawPressure: Int =
            (Int(d[6]) << 2) |
            ((Int(d[7]) >> 6) & 3)
        let pressure11 = (rawPressure << 1) | Int(status & 0x01)

        let tiltX = (((Int(d[7]) << 1) & 0x7e) | (Int(d[8]) >> 7)) - 64
        let tiltY = (Int(d[8]) & 0x7f) - 64
        let distance = (Int(d[9]) >> 2) & 0x3f

        // Boutons. Le tip-switch n'est pas un bit dédié sur les Intuos Pro :
        // Linux le déduit empiriquement de `pression > seuil` (cf.
        // `BTN_TOUCH, t > features->pressure_threshold`). On reproduit cette
        // heuristique avec un petit seuil pour ignorer le bruit hardware.
        let tipDown = pressure11 > Self.pressureTouchThreshold

        let sample = PenSample(
            x: x,
            y: y,
            pressure: pressure11,
            distance: distance,
            tiltX: tiltX,
            tiltY: tiltY,
            tipDown: tipDown,
            barrelButton1: (status & 0x02) != 0,
            barrelButton2: (status & 0x04) != 0,
            eraser: false  // déterminé à l'entrée en proximité (toolID)
        )
        return .pen(sample)
    }

    /// Seuil de pression au-dessus duquel on considère la mine du stylet en
    /// contact avec la surface. Identique à la valeur retenue par OpenTabletDriver.
    private static let pressureTouchThreshold = 1
}
