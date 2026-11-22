# Skener (česky)

Dávkové skenování pro Mac přes síť, bez ovladačů a aplikací od Canonu. Se skenerem komunikuje
standardem **eSCL / AirScan** (skenování přes AirPrint), který umí většina síťových tiskáren Canon
i-SENSYS / imageCLASS, PIXMA a MAXIFY zhruba od roku 2017. Seznam modelů je v [anglickém README](README.md#supported-printers).

## Co umí

- **Předvolby** Faktury / Smlouvy / Účtenky / Fotky. Ukládají se a dají se přejmenovat a duplikovat.
- **Podavač i sklo**, oboustranné skenování, barevně i v odstínech šedi, A4 / A5 / Letter / Legal
- **Živé náhledy** stránek během skenování
- **Dělení dávky** podle prázdného listu, po N stranách, po jedné straně, nebo vše do jednoho PDF.
  Při oboustranném skenu rozdělí dokument jen list prázdný z *obou* stran. Prázdné ruby se jen zahodí.
- **Vyřazené prázdné strany** zůstávají vidět a jdou jedním klikem vrátit. Citlivost je nastavitelná.
- **Ruční úpravy**: přejmenování, sloučení, rozdělení, otočení a smazání (pravým tlačítkem na náhledu)
- **„Přiskenovat do posledního“**, když se vše nevejde do podavače, nebo při skenování více stran ze skla
- **PDF s prohledávatelným textem** (OCR přes systémové rozpoznávání textu)
- **Pojmenování** `Faktura_{datum}_{č}`. Čísla navazují na soubory, které už ve složce jsou.
- **Protokol komunikace** (⌘L, ukládá se také do `~/Library/Logs/Skener.log`)

## Instalace

Potřebujete macOS 14 nebo novější a Xcode, nebo jen Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/micfold/mac-canon-scanner.git ~/Developer/mac-canon-scanner
cd ~/Developer/mac-canon-scanner
./scripts/build-app.sh
open build/Skener.app
```

Při prvním spuštění povolte **přístup k místní síti**
(Nastavení systému → Soukromí a zabezpečení → Místní síť → Skener).

## Test spojení z Terminálu

```bash
swift run skener-cli caps 192.168.1.50
swift run skener-cli status 192.168.1.50
swift run skener-cli scan 192.168.1.50 --out ~/Desktop/test-sken -v
```

`scan` bere z podavače oboustranně. `--sklo`, `--jednostranne`, `--seda` a `--dpi 150` to změní.
Přepínač `-v` vypíše celou komunikaci se skenerem.

## Když něco nejde

| Hláška | Co s tím |
|---|---|
| Nelze se připojit… | Zkontrolujte IP adresu a zkuste `skener-cli caps <ip>`. |
| HTTP 403 / 401 | Na tiskárně může být skenování přes síť vypnuté. Ve webovém rozhraní v nastavení sítě zapněte AirPrint / IPP skenování. |
| Tiskárna ukazuje „Skenování…“, ale nic nepřijde | Otevřete protokol (⌘L) a pošlete ho v issue. |
| Zbytečně vyřazuje stránky | Posuňte citlivost doleva. Vyřazené stránky vrátíte tlačítkem *Vrátit*. |
