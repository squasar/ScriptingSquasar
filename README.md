# ScriptingSquasar

`ScriptingSquasar`, günlük geliştirme ve depo bakım işlerini daha güvenli,
tekrarlanabilir ve anlaşılır hâle getiren PowerShell ve otomasyon scriptleri
için oluşturulmuş bir koleksiyondur.

Depodaki ilk araç `Remove-MergedWorktrees.ps1` dosyasıdır. İleride benzer Git,
Windows, worktree, build çıktısı ve geliştirme ortamı bakım işlerini hedefleyen
başka scriptler de aynı depoya eklenebilir. Her yeni scriptin amacı, riskleri ve
kullanım örnekleri kendi belgelendirmesiyle açıkça belirtilecektir.

## Remove-MergedWorktrees.ps1

`Remove-MergedWorktrees.ps1`, bir kök klasörün altındaki Git depolarını ve bu
depolara kayıtlı linked worktree'leri bulan, yalnızca temiz olduğu ve `main`
dalına merge edildiği doğrulanabilen ikincil worktree'leri kaldıran Windows
PowerShell temizlik scriptidir.

Script ayrıca istenirse `origin` bilgisini yeniler ve yerel `main` dalını
`origin/main` seviyesine yalnızca güvenli bir fast-forward mümkünse getirir.
Windows'taki uzun dosya yolu (`Filename too long`) sorunları için Git'in
uzun-yol desteğini işlem bazında etkinleştirir ve kontrollü bir fiziksel
temizleme tamamlama mekanizması içerir.

> [!IMPORTANT]
> Script varsayılan olarak **önizleme modunda** çalışır. Gerçek güncelleme veya
> kaldırma işlemleri ancak `-Apply` parametresi verildiğinde yapılır.

## Neden yazıldı?

Bir projede her görev veya pull request için ayrı Git worktree açıldığında,
merge sonrasında aşağıdaki kalıntılar birikebilir:

- Artık işi bitmiş linked worktree klasörleri
- Git kaydı kaldırıldığı hâlde uzun dosya yolları yüzünden diskte kalmış
  klasörler
- Güncel olmayan yerel `main`
- Flutter, Node.js, Android veya benzeri araçların oluşturduğu çok derin
  `build`, `.dart_tool`, `node_modules` ve önbellek yolları

Script bu temizliği otomatikleştirirken yanlış klasörü silmemek için temkinli
davranır. Bir worktree ancak kayıtlı, erişilebilir, kök klasör içinde, temiz ve
merge edilmişse kaldırılabilir.

## Temel özellikler

- Kök klasörün altındaki Git depolarını özyinelemeli olarak bulur.
- Aynı Git deposuna bağlı birden fazla worktree'yi ortak Git dizinine göre
  tekilleştirir.
- Ana worktree'yi her zaman korur.
- `main`, detached, locked, prunable, kök klasör dışındaki veya erişilemeyen
  worktree'leri kaldırmaz.
- Commit geçmişini kullanarak worktree dalının `main` içinde olup olmadığını
  doğrular.
- İsteğe bağlı olarak GitHub CLI ile merge edilmiş PR kontrolü yapar.
- Değiştirilmiş veya izlenmeyen dosyaları bulunan worktree'leri korur.
- Varsayılan olarak ignored dosyaları da değişiklik sayarak korur.
- `git worktree remove --force` kullanmaz.
- Git branch'lerini silmez.
- Bağımsız Git clone klasörlerini silmez.
- Yerel `main` dalını reset veya zorunlu merge ile değiştirmez.
- Sistem, global veya repo seviyesindeki Git ayarlarını değiştirmez.

## Gereksinimler

- Windows PowerShell 5.1 veya daha yeni uyumlu PowerShell
- Git for Windows ve `PATH` içinde erişilebilir `git`
- İsteğe bağlı: GitHub CLI (`gh`) ve aktif GitHub oturumu

GitHub CLI yalnızca `-CheckGitHubPRs` kullanıldığında gerekir. `gh` yoksa script
çalışmaya devam eder ancak squash-merge edilmiş PR'ları GitHub üzerinden
doğrulayamaz. Git geçmişiyle doğrulanabilen normal merge'ler yine işlenebilir.

## Önerilen kullanım akışı

Temizliği iki aşamada yapmak en güvenli yöntemdir.

### 1. Önce önizleme yapın

```powershell
.\Remove-MergedWorktrees.ps1 `
    -Root 'C:\Dev\github' `
    -UpdateMain `
    -CheckGitHubPRs `
    -SkipGeneratedDirs `
    -AllowIgnored
```

Bu komutta `-Apply` bulunmadığı için klasör silinmez ve yerel `main`
değiştirilmez. Script yalnızca yapılabilecek işlemleri raporlar.

### 2. Çıktıyı kontrol edip uygulayın

```powershell
.\Remove-MergedWorktrees.ps1 `
    -Root 'C:\Dev\github' `
    -UpdateMain `
    -CheckGitHubPRs `
    -SkipGeneratedDirs `
    -AllowIgnored `
    -Apply
```

Bu kullanım:

1. `origin` remote'unu fetch eder.
2. Yerel `main` temizse ve `origin/main` dalının gerisindeyse fast-forward yapar.
3. Merge edildiği doğrulanan temiz linked worktree'leri kaldırır.
4. Ana worktree'yi, branch'leri ve bağımsız clone'ları korur.

## Parametreler

### `-Root <yol>`

Taranacak kök klasörü belirler. Verilmezse mevcut çalışma dizini kullanılır.

```powershell
.\Remove-MergedWorktrees.ps1 -Root 'C:\Dev\github'
```

### `-Apply`

Önizlemeyi gerçek işleme dönüştürür. Bu parametre olmadan klasörler kaldırılmaz
ve yerel `main` güncellenmez.

### `-Fetch`

`origin` remote'unu günceller. Fetch başarısız olursa script eski
`origin/main` bilgisine güvenmez ve ilgili depoda worktree silmez.

`-UpdateMain` zaten fetch yaptığı için ikisini birlikte vermek gerekli değildir.

### `-UpdateMain`

`origin` bilgisini fetch eder ve yerel `main` için güvenli fast-forward dener.
Güncelleme yalnızca şu koşullarda yapılır:

- `origin` başarıyla fetch edilmiştir.
- Hem `main` hem de `origin/main` vardır.
- `main` bir worktree içinde checkout edilmiştir.
- Main worktree kilitli değildir ve `Root` içindedir.
- Yerel `main`, `origin/main` dalının atasıdır; dallar ayrışmamıştır.
- Main worktree tamamen temizdir; izlenmeyen dosya da yoktur.
- `-Apply` verilmiştir.

Script main'i temizlemek için dosya silmez, stash oluşturmaz, reset atmaz veya
otomatik conflict çözmez. Main kirliyse `[MAIN ATLANDI]` mesajıyla güvenli
şekilde durur.

Güncellemenin yönü her zaman şöyledir:

```text
GitHub origin/main  --->  yerel main
```

Script `push` veya `force-push` yapmaz; GitHub'daki `main` dalını geriye çekmez.

### `-CheckGitHubPRs`

Git geçmişi tek başına yeterli olmadığında GitHub CLI üzerinden merge edilmiş
PR arar. PR'ın:

- base dalının `main` olması,
- merge edilmiş olması,
- head SHA değerinin worktree HEAD değeriyle birebir eşleşmesi

gerekir. Bu kontrol özellikle squash merge senaryolarında faydalıdır.

### `-AllowIgnored`

Normal davranışta ignored dosyalar da worktree'yi kirli sayar ve klasör
korunur. Bu parametre verildiğinde ignored dosyalar temizlik kararını engellemez
ve worktree kaldırılırken silinebilir.

> [!WARNING]
> `-AllowIgnored`; ignored build çıktılarının, yerel önbelleklerin veya ignored
> gizli dosyaların korunmayacağı anlamına gelir. İzlenen, değiştirilmiş veya
> izlenmeyen normal dosyalar yine worktree'nin kaldırılmasını engeller.

Bu parametre ana `main` worktree'nin temizlik kontrolünü gevşetmez. Yerel main,
`-UpdateMain` için her durumda tamamen temiz olmalıdır.

### `-SkipGeneratedDirs`

Repo keşfi sırasında aşağıdaki bilinen üretim ve önbellek klasörlerinin altına
inmez:

```text
node_modules, .dart_tool, .next, .gradle, .venv, venv,
__pycache__, .pub-cache, build, dist, coverage, .turbo
```

Bu seçenek taramayı hızlandırır. Bu klasörlerin altında özellikle saklanan
bağımsız bir Git deposu varsa o depo taranmaz.

### `-MainRef Auto|Local|Origin`

Merge doğrulamasında kullanılacak ana referansı seçer:

- `Auto` (varsayılan): Önce `origin/main`, yoksa yerel `main`
- `Origin`: Yalnızca `origin/main`
- `Local`: Yalnızca yerel `main`

Güncel uzak bilgiyle temizlik yapmak için `Auto` veya `Origin` seçeneğini
`-Fetch`/`-UpdateMain` ile kullanmak önerilir.

### `-RecoverOrphanedPaths <tam-yol-listesi>`

Eski bir `git worktree remove` işlemi Git metadata kaydını kaldırdığı hâlde
uzun yol hatası nedeniyle fiziksel klasörü bıraktıysa, artık kayıtlı olmayan bu
klasör normal worktree listesinden görülemez. Parametre yalnızca açıkça verilen
tam yolları güvenlik kontrollerinden geçirir.

Önce önizleme:

```powershell
.\Remove-MergedWorktrees.ps1 `
    -Root 'C:\Dev\github' `
    -SkipGeneratedDirs `
    -AllowIgnored `
    -RecoverOrphanedPaths 'C:\Dev\github\MyRepo-old-worktree'
```

Ardından aynı komuta `-Apply` eklenebilir:

```powershell
.\Remove-MergedWorktrees.ps1 `
    -Root 'C:\Dev\github' `
    -SkipGeneratedDirs `
    -AllowIgnored `
    -RecoverOrphanedPaths 'C:\Dev\github\MyRepo-old-worktree' `
    -Apply
```

Birden fazla tam yol virgülle verilebilir:

```powershell
-RecoverOrphanedPaths 'C:\Dev\github\MyRepo-task-a','C:\Dev\github\MyRepo-task-b'
```

Yetim kalıntı kurtarmanın güvenlik sınırları:

- Wildcard kabul edilmez; mutlak ve tam yol gerekir.
- `-AllowIgnored` zorunludur çünkü Git metadata'sı olmayan içeriğin sınıfı
  güvenilir biçimde belirlenemez.
- Hedef doğrudan `Root` altında olmalıdır.
- Hedef adı, kayıtlı ana repo adını `RepoAdi-...` biçiminde takip etmelidir.
- Hedef hâlen kayıtlı bir worktree ise bu yol kullanılmaz.
- Klasör ağacında `.git` bulunursa silme reddedilir.
- Reparse point olan kök hedef reddedilir.
- Adında `preservation`, `preserve`, `backup`, `archive` veya `yedek` bulunan
  klasörler korunur.
- Yetim klasörler hiçbir zaman otomatik seçilmez.

## Worktree kaldırma koşulları

Kayıtlı bir ikincil worktree'nin kaldırılması için aşağıdakilerin tamamı
sağlanmalıdır:

1. Ana worktree olmamalıdır.
2. `main` dalını kullanmamalıdır.
3. Bare, detached, locked veya prunable olmamalıdır.
4. `Root` altında ve erişilebilir olmalıdır.
5. Kökü reparse point olmamalıdır.
6. Branch'in merge edildiği Git geçmişiyle veya doğrulanmış GitHub PR'ıyla
   kanıtlanmalıdır.
7. Worktree temiz olmalıdır.
8. Gerçek kaldırma için `-Apply` verilmelidir.

Kaldırma, silinen worktree'nin içinden değil ana worktree üzerinden yapılır.
Bu, Windows'ta çalışan `git.exe` sürecinin kendi çalışma dizinini silmeye
çalışmasından kaynaklanan hataları önler.

## Uzun dosya yolu desteği

Windows'ta bir worktree kökünün yolu kısa olsa bile içindeki Flutter, Android,
Node.js veya test çıktıları eski `MAX_PATH` sınırını aşabilir. Bu durumda Git:

```text
error: failed to delete '...': Filename too long
```

hatası verebilir.

Script her Git çağrısına yalnızca o süreç için aşağıdaki ayarı uygular:

```text
-c core.longpaths=true
```

Kalıcı `git config` değişikliği yapmaz. Git worktree kaydını kaldırıp fiziksel
klasörün bir bölümünü bıraktıysa script durumu yeniden doğrular. Hedef artık
kayıtlı değilse, daha önce bütün güvenlik kontrollerinden geçmişse ve içinde
korunması gereken başka `.git` işareti yoksa `\\?\` extended-length Windows
yollarıyla temizliği tamamlayabilir.

Reparse point alt ağaçları takip edilmez; yalnızca bağlantının kendisi
kaldırılır. Böylece hedef klasörün dışındaki içeriklere geçilmez.

## Çıktıyı okuma

Sık görülen mesajlar:

- `[REPO BULUNDU]`: Benzersiz bir Git deposu bulundu.
- `[FETCH]`: `origin` bilgisi yenileniyor.
- `[MAIN GUNCELLENEBILIR]`: Önizlemede main fast-forward edilebilir.
- `[MAIN GUNCELLENIYOR]`: Yerel main fast-forward ediliyor.
- `[MAIN GUNCELLENDI]`: Yerel main başarıyla güncellendi.
- `[MAIN ATLANDI]`: Main güvenlik koşullarından biri sağlanmadı.
- `[KORUNDU: ana worktree]`: Ana worktree bilerek korunuyor.
- `[KALDIRILABILIR]`: Önizlemede güvenli kaldırma adayı.
- `[KALDIRILIYOR]`: Kayıtlı worktree kaldırılıyor.
- `[KALDIRILDI]`: Kaldırma tamamlandı.
- `[KALDIRILDI: UZUN-YOL TAMAMLAMA]`: Git metadata'yı kaldırdıktan sonra kalan
  uzun-yollu klasör güvenli mekanizmayla tamamlandı.
- `[ATLANDI: ...]`: Worktree belirtilen güvenlik nedeniyle korunuyor.
- `[YETIM KALDIRILABILIR]`: Açıkça verilen yetim klasör önizlemede uygun.
- `[YETIM KALINTI KALDIRILDI]`: Yetim fiziksel klasör kaldırıldı.

Sonuç satırları normal worktree, uzun-yol tamamlama ve yetim kalıntı sayılarını
ayrı ayrı gösterir.

## Scriptin özellikle yapmadıkları

Bu script:

- GitHub'da veya başka bir remote'da branch silmez.
- Yerel branch silmez.
- Commit oluşturmaz.
- Push veya force-push yapmaz.
- Yerel değişiklikleri stash etmez.
- `git reset --hard` veya `git clean` çalıştırmaz.
- Merge conflict çözmez.
- Test veya build çalıştırmaz.
- Bağımsız clone klasörlerini temizlik adayı saymaz.
- Kayıtsız klasörleri `-RecoverOrphanedPaths` olmadan silmez.

## Sorun giderme

### `gh (GitHub CLI) bulunamadi`

GitHub CLI kurulu değildir veya `PATH` içinde değildir. Script Git geçmişiyle
devam eder ancak squash merge PR doğrulaması devre dışı kalır.

### `[MAIN ATLANDI] main temiz degil`

Main worktree'de değiştirilmiş, staged veya izlenmeyen dosya vardır. Script bu
dosyalara dokunmaz. Önce değişiklikleri inceleyin; gerekiyorsa commit veya stash
ile koruyun. Ardından komutu yeniden çalıştırın.

### `[MAIN ATLANDI] Yerel main origin/main dalindan ayrilmis`

Yerel ve uzak main farklı commit'lere sahiptir. Script otomatik merge veya reset
yapmaz. Ayrışmayı kullanıcı olarak inceleyip çözmeniz gerekir.

### `[ATLANDI: merge dogrulanamadi]`

Branch ucu seçilen main referansının geçmişinde değildir ve GitHub PR kontrolü
de merge'i doğrulayamamıştır. Worktree güvenlik için korunur.

### Dosya başka bir işlem tarafından kullanılıyor

IDE, test süreci, terminal, antivirüs veya başka bir uygulama klasörde açık
dosya tutuyor olabilir. İlgili işlemi kapatıp aynı açık hedefi yeniden deneyin.
Script kilidi zorla aşmaz.

## Güvenli kullanım özeti

1. Önce `-Apply` olmadan çalıştırın.
2. `[KALDIRILABILIR]` ve `[YETIM KALDIRILABILIR]` yollarını tek tek kontrol edin.
3. Main kirliyse değişiklikleri silmeden önce inceleyip koruyun.
4. `-AllowIgnored` kullanırken ignored dosyaların silinebileceğini unutmayın.
5. Yetim klasör kurtarmada yalnızca kesin olarak bildiğiniz tam yolları verin.
6. Çıktı doğruysa aynı komutu `-Apply` ile yeniden çalıştırın.

## Dosyalar

- `Remove-MergedWorktrees.ps1`: Temizlik ve main güncelleme scripti
- `README.md`: Kullanım ve güvenlik belgesi
- `LICENSE`: MIT lisansı

## Gelecek scriptler

Bu depo tek bir araca bağlı değildir. Aynı güvenli tasarım yaklaşımını izleyen
yeni bakım ve otomasyon scriptleri ileride eklenebilir. Yeni araçlar mümkün
olduğunca:

- varsayılan olarak önizleme modunda çalışacak,
- yıkıcı işlemler için açık bir uygulama parametresi isteyecek,
- işlem sınırlarını ve korunacak verileri belgeleyerek ilerleyecek,
- kişisel yollar, hesap bilgileri veya credential içermeyecektir.

## Lisans

Bu depodaki içerik [MIT Lisansı](LICENSE) altında sunulur.
