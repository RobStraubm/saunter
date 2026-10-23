"""FitShow-Pakete bauen und lesen, Schritt-Schaetzung – ohne Geraet."""
import pytest

from walk_session import PKT_FOOTER, PKT_HEADER, SYS_STATUS, build_packet, estimate_steps, parse_status_packet


def test_paket_hat_rahmen_und_xor_pruefsumme():
    payload = bytes([0x53, 0x02, 0x14])
    packet = build_packet(payload)
    assert packet[0] == PKT_HEADER and packet[-1] == PKT_FOOTER
    assert packet[1:-2] == payload
    assert packet[-2] == 0x53 ^ 0x02 ^ 0x14


def status_packet(speed=25, seconds=600, distance=4, kcal=30, steps=900):
    data = bytearray(17)
    data[0], data[1], data[2] = PKT_HEADER, SYS_STATUS, 3
    data[3] = speed
    data[5], data[6] = seconds & 0xFF, seconds >> 8
    data[7], data[8] = distance & 0xFF, distance >> 8
    data[9], data[10] = kcal & 0xFF, kcal >> 8
    data[11], data[12] = steps & 0xFF, steps >> 8
    return bytes(data)


def test_statuspaket_wird_gelesen():
    p = parse_status_packet(status_packet(speed=25, seconds=600, steps=900))
    assert p["speed"] == 2.5
    assert p["seconds_elapsed"] == 600
    assert p["step_count"] == 900


def test_zu_kurzes_oder_fremdes_paket_wird_ignoriert():
    assert parse_status_packet(bytes(5)) is None
    other = bytearray(status_packet())
    other[1] = SYS_STATUS + 1
    assert parse_status_packet(bytes(other)) is None


@pytest.mark.parametrize("sex", ["male", "female"])
def test_schritte_wachsen_mit_der_strecke(sex):
    assert estimate_steps(2.0, 180, sex) == pytest.approx(2 * estimate_steps(1.0, 180, sex), abs=1)


def test_groessere_menschen_machen_weniger_schritte():
    assert estimate_steps(1.0, 190, "male") < estimate_steps(1.0, 160, "male")
