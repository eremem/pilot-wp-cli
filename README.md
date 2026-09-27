**Polski** · [English](README.en.md)

# pilot-wp-cli

Zestaw skryptów, dzięki którym kanały [Pilota WP](https://pilot.wp.pl) obejrzysz na telewizorze przez domowy serwer z [tvheadend](https://tvheadend.org/) — na przykład w Kodi — zamiast w oficjalnej aplikacji. Skrypty działają na Linuksie, np. na Raspberry Pi z xbianem.

Co dostajesz:

- **Listę kanałów dla tvheadend** — z logo i podziałem na kategorie. Trafiają na nią kanały bezpłatne i te, które obejmuje Twój abonament.
- **Obraz i dźwięk w oryginalnej jakości** — strumienie nie są przekodowywane, a wszystkie ścieżki dźwiękowe są zachowane.
- **Czytelną informację zamiast błędu** — gdy kanału nie da się włączyć (np. przekroczono limit jednoczesnych transmisji na koncie), na ekranie pojawia się plansza z wyjaśnieniem.
- **Opcjonalnie: kanały chronione DRM** (np. TVN) — jeśli dostarczysz własny plik urządzenia Widevine (zobacz [Kanały z DRM](#opcjonalnie-kanały-z-drm)).

> To nieoficjalny projekt, niezwiązany z wp.pl. Pozwala oglądać tylko to, do czego masz dostęp na swoim koncie. Jeśli oficjalna aplikacja Pilot WP działa na Twoim urządzeniu, korzystaj z niej. Zobacz [zastrzeżenia](DISCLAIMER.md).

## Spis treści

- [Czego potrzebujesz](#czego-potrzebujesz)
- [Krok 1. Skopiuj skrypty na serwer](#krok-1-skopiuj-skrypty-na-serwer)
- [Krok 2. Zainstaluj brakujące programy](#krok-2-zainstaluj-brakujące-programy)
- [Krok 3. Połącz konto Pilot WP](#krok-3-połącz-konto-pilot-wp)
- [Krok 4. Sprawdź, czy wszystko działa](#krok-4-sprawdź-czy-wszystko-działa)
- [Krok 5. Utwórz listę kanałów](#krok-5-utwórz-listę-kanałów)
- [Krok 6. Dodaj kanały do tvheadend](#krok-6-dodaj-kanały-do-tvheadend)
- [Krok 7. Nie pozwól, żeby sesja wygasła](#krok-7-nie-pozwól-żeby-sesja-wygasła)
- [Opcjonalnie: kanały z DRM](#opcjonalnie-kanały-z-drm)
- [Opcjonalnie: automatyczne odświeżanie listy kanałów](#opcjonalnie-automatyczne-odświeżanie-listy-kanałów)
- [Typowe problemy](#typowe-problemy)
- [Więcej informacji](#więcej-informacji)

## Czego potrzebujesz

- **Konto w Pilocie WP.** Kanały bezpłatne działają bez abonamentu; pozostałe — jeśli masz je w pakiecie.
- **Serwer z Linuksem i działającym tvheadend** — np. Raspberry Pi z xbianem, Raspberry Pi OS albo Ubuntu. Potrzebny jest dostęp do terminala serwera (np. przez SSH) i uprawnienia `sudo`.
- **Komputer w tej samej sieci domowej** z przeglądarką Chrome albo Firefox — do połączenia konta.
- **Program do oglądania**, który łączy się z tvheadend — np. Kodi z dodatkiem *Tvheadend HTSP Client*.

**Ścieżki w przykładach.** Poniższe polecenia zakładają, że tvheadend działa jako użytkownik `xbian`, a skrypty leżą w katalogu `/home/xbian/.hts/tvheadend/scripts/pilot-wp-cli`. W innym systemie podstaw własne wartości. Użytkownika, na którym działa tvheadend, sprawdzisz poleceniem:

```bash
ps -o user= -C tvheadend
```

(w Debianie, Ubuntu i Raspberry Pi OS jest to zwykle `hts`, a katalog domowy tvheadend to `/home/hts/.hts/tvheadend`).

## Krok 1. Skopiuj skrypty na serwer

Skrypty są dostępne na GitHubie: https://github.com/eremem/pilot-wp-cli. Najprościej pobrać je bezpośrednio na serwer.

### Sposób zalecany: przez git

**Na serwerze (w terminalu):**

```bash
sudo apt install git
sudo git clone https://github.com/eremem/pilot-wp-cli.git /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli
cd /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli
sudo chmod +x pilot-wp-*
```

Później zaktualizujesz skrypty jednym poleceniem (Twoje ustawienia i zapisana sesja zostaną nietknięte):

```bash
sudo -u xbian git -C /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli pull
```

### Inny sposób: archiwum ZIP

1. **Na komputerze:** na stronie projektu kliknij **Code** → **Download ZIP** i rozpakuj pobrane archiwum.
2. Skopiuj rozpakowany katalog do swojego katalogu domowego na serwerze — np. przez `scp`, WinSCP albo udział sieciowy. Zwykle nazywa się on `pilot-wp-cli-main`; jeśli Twój nazywa się inaczej, zmień nazwę w poleceniu poniżej.
3. **Na serwerze (w terminalu):** przenieś pliki na miejsce, przejdź do katalogu i nadaj skryptom prawo uruchamiania:

   ```bash
   sudo mkdir -p /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli
   sudo cp -r ~/pilot-wp-cli-main/. /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli/
   cd /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli
   sudo chmod +x pilot-wp-*
   ```

Niezależnie od sposobu wszystkie kolejne polecenia wykonuj w katalogu `/home/xbian/.hts/tvheadend/scripts/pilot-wp-cli`.

## Krok 2. Zainstaluj brakujące programy

Skrypty potrzebują kilku popularnych programów (m.in. `ffmpeg`, `curl`, `jq` i `python3`). Sprawdzi je i doinstaluje `pilot-wp-deps`.

**Na serwerze:**

```bash
./pilot-wp-deps                # tylko raport: co jest, a czego brakuje (niczego nie zmienia)
sudo ./pilot-wp-deps install   # doinstaluj brakujące programy
```

Jeśli nie planujesz oglądać kanałów z DRM, dodaj `--no-drm` — wtedy zostanie pominięte wszystko, co jest potrzebne tylko do nich:

```bash
sudo ./pilot-wp-deps install --no-drm
```

Na koniec przekaż katalog użytkownikowi tvheadend, żeby tvheadend mógł uruchamiać skrypty i czytać ich pliki:

```bash
sudo chown -R xbian:xbian /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli
```

> Automatyczna instalacja działa w systemach opartych na Debianie (xbian, Raspberry Pi OS, Ubuntu). W innych dystrybucjach `pilot-wp-deps` tylko wypisze, czego brakuje — te programy zainstalujesz wtedy samodzielnie.

## Krok 3. Połącz konto Pilot WP

Skrypty nie znają Twojego hasła i same się nie logują — strona logowania Pilota WP jest chroniona przed automatami. Logujesz się więc jak zwykle w przeglądarce, a potem przekazujesz serwerowi sesję z tej przeglądarki. Najprościej zrobić to przez tymczasową stronę, którą uruchamia serwer.

### Sposób zalecany: strona w przeglądarce

1. **Na serwerze:** uruchom (koniecznie jako użytkownik tvheadend):

   ```bash
   sudo -u xbian ./pilot-wp-login --web
   ```

   Polecenie wypisze adres strony, np. `http://192.168.1.20:8199/`, oraz sześciocyfrowy kod.
2. **Na komputerze:** otwórz ten adres w przeglądarce. Strona krok po kroku pokaże, co zrobić: zalogować się na pilot.wp.pl, skopiować z narzędzi przeglądarki jedno żądanie, wkleić je na stronie i wpisać kod z terminala.
3. Serwer sprawdza w Pilocie WP, czy przekazana sesja działa, i dopiero wtedy ją zapisuje — nieudana próba niczego nie zepsuje. Po udanym połączeniu strona to potwierdzi, a polecenie na serwerze się zakończy.

Strona działa tylko w sieci domowej. Wyłącza się sama po udanym połączeniu, po 15 minutach albo po 5 błędnych kodach — wtedy po prostu uruchom polecenie jeszcze raz.

Po połączeniu możesz zamknąć kartę Pilota WP, ale **nie wylogowuj się** tam — wylogowanie zakończy także sesję przekazaną serwerowi.

### Inne sposoby

**Wklejenie w terminalu serwera.** Jeśli nie chcesz uruchamiać strony, możesz wkleić skopiowane żądanie bezpośrednio w terminalu:

1. **Na komputerze, w karcie Pilota WP:** zaloguj się na https://pilot.wp.pl, naciśnij <kbd>F12</kbd> i w panelu narzędzi przejdź na zakładkę **Network** (Chrome) albo **Sieć** (Firefox). Narzędzia deweloperskie Chrome są po angielsku także w polskiej wersji przeglądarki.
2. **W tej samej karcie:** kliknij na stronie dowolny kanał, a potem w polu filtra u góry panelu (**Filter** w Chrome) wpisz `api`.
3. **W zakładce Network / Sieć:** kliknij prawym przyciskiem myszy dowolny wiersz i wybierz:
   - Chrome: **Copy** → **Copy as cURL (bash)** (działa też **Copy as cURL (cmd)**),
   - Firefox: **Kopiuj wartość** → **Kopiuj jako polecenie cURL (POSIX)**.
4. **Na serwerze:** uruchom `sudo -u xbian ./pilot-wp-login`, wybierz `c`, wklej skopiowany tekst i zatwierdź, naciskając <kbd>Enter</kbd> w pustym wierszu.

Zamiast wklejać całe żądanie, możesz też wybrać `v` i przepisać ręcznie dwie wartości ciasteczek: `netviapisessid` i `netviapisessval`. Znajdziesz je w panelu narzędzi przeglądarki: Chrome — zakładka **Application** → **Cookies** → **https://pilot.wp.pl**; Firefox — zakładka **Dane** → **Ciasteczka** → **https://pilot.wp.pl**.

**Skopiowanie sesji z innego serwera.** Jeśli skrypty działają już na innym serwerze, możesz przenieść stamtąd plik `cookies.txt`:

```bash
sudo install -m 600 -o xbian -g xbian cookies.txt /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli/cookies.txt
```

## Krok 4. Sprawdź, czy wszystko działa

**Na serwerze:**

```bash
sudo -u xbian ./pilot-wp-status
```

Polecenie sprawdza zainstalowane programy, połączenie z kontem i gotowość do odtwarzania kanałów z DRM. Niczego nie zmienia. Jeśli na końcu, w sekcji **Summary**, widzisz `ready for free-to-air streaming`, możesz oglądać kanały bez DRM. Ostrzeżenia w sekcji **DRM playback** na tym etapie są normalne.

Informacje o koncie — pakiety z datami ważności oraz kraj, z którego według Pilota WP łączy się serwer — pokaże:

```bash
sudo -u xbian ./pilot-wp-account-info
```

## Krok 5. Utwórz listę kanałów

**Na serwerze:**

```bash
sudo -u xbian ./pilot-wp-m3u channels.m3u
```

Powstanie plik `channels.m3u`, który w następnym kroku wczyta tvheadend. Za pierwszym razem potrwa to kilka minut: skrypt po kolei na chwilę otwiera każdy kanał, żeby sprawdzić, czy jest chroniony DRM (takie kanały dostają w tvheadend etykietę `DRM`). Dlatego najlepiej nie oglądać w tym czasie Pilota WP na innych urządzeniach. Kolejne uruchomienia są szybkie, bo wynik jest zapamiętywany.

Listę trzeba utworzyć ponownie tylko wtedy, gdy zmieni się oferta kanałów (np. dojdzie nowy kanał albo zmienisz pakiet).

## Krok 6. Dodaj kanały do tvheadend

W przeglądarce otwórz panel tvheadend (zwykle `http://ADRES-SERWERA:9981`), a następnie:

1. Przejdź do **Configuration** → **DVB Inputs** → **Networks** i kliknij **Add**. Jako typ wybierz **IPTV Automatic Network**.
2. Wypełnij formularz:
   - **Network name:** np. `Pilot WP`,
   - **URL:** `file:///home/xbian/.hts/tvheadend/scripts/pilot-wp-cli/channels.m3u` (z trzema ukośnikami na początku),
   - odznacz **Scan after creation** i **Idle scan muxes** — skanowanie w tle włączałoby kanały, których nikt nie ogląda, i zajmowało limit jednoczesnych transmisji na koncie.

   Kliknij **Create**.
3. Na liście sieci zaznacz `Pilot WP` i kliknij **Force Scan**. Skanowanie chwilę potrwa, bo każdy kanał zostanie na moment włączony.
4. Przejdź do **Configuration** → **DVB Inputs** → **Services**, kliknij **Map services** → **Map all services** i potwierdź przyciskiem **Map services**.

Kanały pojawią się w **Configuration** → **Channel / EPG** → **Channels** i w każdym programie połączonym z tvheadend, np. w Kodi.

> **Kanały radiowe.** tvheadend rozpoznaje radio dopiero wtedy, gdy stacja zostanie włączona. Jeśli kanał radiowy trafił między kanały telewizyjne, włącz go raz albo w **Services** ustaw mu ręcznie **Service type** na **Radio**.

## Krok 7. Nie pozwól, żeby sesja wygasła

Sesja Pilota WP przedłuża się sama, dopóki jest używana. Jeśli jednak serwer przez dłuższy czas nic nie odtwarza, może wygasnąć — wtedy zamiast obrazu zobaczysz planszę o błędzie uwierzytelnienia i trzeba będzie powtórzyć [krok 3](#krok-3-połącz-konto-pilot-wp). Żeby temu zapobiec, dodaj do harmonogramu (cron) użytkownika tvheadend `pilot-wp-ping`, który co kilka godzin „odświeża” sesję.

**Na serwerze:**

```bash
sudo crontab -u xbian -e
```

i dopisz na końcu wiersz:

```cron
0 */8 * * * /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli/pilot-wp-ping
```

`pilot-wp-ping` nie zajmuje limitu transmisji i niczego nie wypisuje, gdy wszystko jest w porządku. Jeśli sesja mimo to wygaśnie, po prostu połącz konto ponownie.

## Opcjonalnie: kanały z DRM

Niektóre kanały (np. TVN) są chronione systemem Widevine DRM. Domyślnie zamiast nich wyświetla się plansza z informacją. Żeby je oglądać, potrzebujesz własnego **pliku urządzenia Widevine L3** (`.wvd`). Projekt go nie zawiera — tworzysz go sam z emulatora Androida uruchomionego na własnym komputerze i sam odpowiadasz za zgodne z prawem korzystanie z niego (zobacz [zastrzeżenia](DISCLAIMER.md)).

**Zdobycie pliku `.wvd` (w skrócie):**

1. **Na komputerze:** zainstaluj [Android Studio](https://developer.android.com/studio) i w **Device Manager** utwórz urządzenie wirtualne z obrazem systemu **Google APIs** — nie „Google Play”, bo takiego obrazu nie da się uruchomić z uprawnieniami roota, a są one potrzebne.
2. Uruchom emulator i wyodrębnij z niego plik urządzenia narzędziem opartym na Fridzie, np. [KeyDive](https://github.com/hyugogirubato/KeyDive) — postępuj zgodnie z jego instrukcją. Wynikiem jest plik z rozszerzeniem `.wvd`.

**Uruchomienie DRM na serwerze:**

1. Skopiuj plik `.wvd` do podkatalogu `widevine/` w katalogu skryptów i zabezpiecz go:

   ```bash
   sudo chown xbian:xbian widevine/*.wvd
   sudo chmod 600 widevine/*.wvd
   ```

2. Doinstaluj składniki potrzebne do DRM (jeśli w kroku 2 użyłeś `--no-drm`) i ponownie przekaż katalog użytkownikowi tvheadend:

   ```bash
   sudo ./pilot-wp-deps install
   sudo chown -R xbian:xbian /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli
   ```

3. Włącz odtwarzanie DRM w pliku ustawień. Jeśli nie masz jeszcze pliku `config.env`, utwórz go z przykładu:

   ```bash
   sudo -u xbian cp config.env.example config.env
   sudo -u xbian chmod 600 config.env
   ```

   Otwórz `config.env` w edytorze (np. `sudo -u xbian nano config.env`) i zamień wiersz `#PILOT_WP_DRM_ENABLE=0` na:

   ```bash
   PILOT_WP_DRM_ENABLE=1
   ```

4. Sprawdź wynik poleceniem `sudo -u xbian ./pilot-wp-status` — w sekcji **DRM playback** powinno się pojawić `DRM ready  : yes`.

Listy kanałów nie trzeba tworzyć od nowa — kanały z DRM już na niej są.

## Opcjonalnie: automatyczne odświeżanie listy kanałów

Listę kanałów można odświeżać automatycznie, np. raz dziennie przez cron. **Robisz to jednak na własne ryzyko:** gdy Pilot WP zmieni nazwę lub logo kanału albo go usunie, tvheadend po wczytaniu nowej listy potraktuje go jak nową usługę, a starą usunie — razem z przypisaniem do kanału i jego ustawieniami (np. numerem). Trzeba będzie wtedy ponownie przypisać usługi (krok 6, punkt 4), a niektóre ustawienia kanału poprawić ręcznie.

Dlatego zalecamy tworzenie listy ręcznie ([krok 5](#krok-5-utwórz-listę-kanałów)), gdy zauważysz zmianę w ofercie, a potem sprawdzenie kanałów w tvheadend. Jeśli mimo to wolisz automatyczne odświeżanie, dodaj do crona użytkownika tvheadend (`sudo crontab -u xbian -e`):

```cron
0 4 * * * /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli/pilot-wp-m3u /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli/channels.m3u
```

## Typowe problemy

- **Plansza o błędzie uwierzytelnienia („Błąd uwierzytelnienia”)** — sesja wygasła albo tvheadend nie może odczytać pliku `cookies.txt`, bo należy on do innego użytkownika. Połącz konto ponownie ([krok 3](#krok-3-połącz-konto-pilot-wp)), koniecznie z `sudo -u xbian`, i sprawdź wynik poleceniem `sudo -u xbian ./pilot-wp-status`.
- **Plansza o przekroczonym limicie transmisji** — na koncie ogląda się już tyle kanałów naraz, ile pozwala Pilot WP (liczą się też inne urządzenia i otwarte karty przeglądarki). Zatrzymaj oglądanie gdzie indziej. Listę urządzeń zalogowanych na koncie pokaże `sudo -u xbian ./pilot-wp-sessions`, a niepotrzebną sesję usuniesz poleceniem `sudo -u xbian ./pilot-wp-sessions remove NUMER`.
- **Plansza o kanale chronionym DRM** — odtwarzanie DRM jest wyłączone albo nie działa. Zobacz [Kanały z DRM](#opcjonalnie-kanały-z-drm) i sprawdź sekcję **DRM playback** w wyniku `pilot-wp-status`. Jeśli wcześniej działało, a przestało, plik `.wvd` mógł zostać zablokowany przez Google — potrzebny będzie nowy.
- **W tvheadend nie ma żadnych kanałów** — sprawdź, czy adres listy ma trzy ukośniki (`file:///…`), czy plik `channels.m3u` istnieje i należy do użytkownika tvheadend, a potem ponownie wykonaj **Force Scan** i **Map services** (krok 6).
- **Obraz się zacina** — zwiększ zapas danych, który skrypty pobierają z wyprzedzeniem. W `config.env` (utwórz go jak w sekcji o DRM, punkt 3) zamień wiersz `#PILOT_WP_DASHLIVE_ARGS=` na `PILOT_WP_DASHLIVE_ARGS="--prebuffer 30"`. Przy wolnym łączu możesz też obniżyć jakość obrazu: `PILOT_WP_DASHLIVE_ARGS="--prebuffer 30 --max-video-bw 4000000"`.
- **Kanał radiowy jest na liście kanałów telewizyjnych** — zobacz uwagę o kanałach radiowych w [kroku 6](#krok-6-dodaj-kanały-do-tvheadend).
- **Brak programu telewizyjnego (EPG)** — skrypty nie dostarczają programu. Możesz podłączyć w tvheadend zewnętrzne źródło EPG (XMLTV).
- **Strona logowania się nie otwiera** — komputer musi być w tej samej sieci domowej co serwer. Upewnij się, że używasz adresu wypisanego w terminalu i że zapora sieciowa serwera przepuszcza port `8199` (inny port ustawisz opcją `--port`).
- **„Permission denied” przy uruchamianiu skryptów** — skrypty straciły prawo uruchamiania, np. przy kopiowaniu z Windowsa. Wykonaj ponownie `sudo chmod +x pilot-wp-*`.

## Więcej informacji

- [config.env.example](config.env.example) — wszystkie ustawienia z wartościami domyślnymi.
- [DISCLAIMER.md](DISCLAIMER.md) — zastrzeżenia prawne.
- [LICENSE](LICENSE) — licencja.
