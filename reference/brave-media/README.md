# Brave 미디어 기능 선별 결과

2026-11-13 · 목적: Stream Browser 개인용 iPhone 앱의 구현량을 줄이기 위한 소스 선별

**결론: 다운로드 처리의 일부를 이식하고, 브라우저 화면·저장소·보안 정책은 작게 구성한다. Brave의 Playlist 모듈 전체를 의존성으로 추가하지 않는다.**

이 폴더는 원본 참고 자료다. 독립 실행 가능한 앱이나 빌드되는 Swift Package가 아니다. 원본의 import를 지웠다고 의존성 분리가 끝나는 것은 아니다. 이번 작업은 필요한 원본 추출과 코드 수준의 이식 범위 결정까지다.

전체 앱에는 [보완 기능 명세 v1.2](../../docs/Stream-Browser-보완기능-v1.2.md)의 앱 잠금·추적 차단·탭·저장공간·파일 관리·오류 복구도 포함한다. 아래 최소 구성은 추출 코드의 이식 경계이며 완제품 기능을 축소하는 목록이 아니다.

## 확보한 원본

- 저장소: [brave/brave-core](https://github.com/brave/brave-core)
- 고정 commit: `b38bae283b5a99943d114655f76a495d901a68b0`
- 선택 소스: Swift 7개 + JavaScript 1개, 총 **78,267바이트**.
- 의존성 증거 `Package.swift`와 `LICENSE` 포함 원본 10개: **121,961바이트**.
- Chromium checkout·BraveCore 바이너리·npm/Swift 패키지는 내려받지 않았다.
- 원본은 수정하지 않았고, 10개 모두 Git blob SHA-1이 upstream metadata와 일치함을 확인했다.
- 모든 출처·원본 경로·선별 판정·해시는 [manifest.json](./manifest.json)에 기록했다.

Git hash 일치는 복사 정확성을 확인하는 수단이다. 코드의 보안성이나 iOS 실행 성공을 의미하지 않는다.

## 가져갈 부분과 제외할 부분

| 원본 | 판정 | 활용 범위 | 먼저 바꿀 부분 |
|---|---|---|---|
| [PlaylistDownloadManager.swift](./upstream/ios/brave-ios/Sources/Playlist/PlaylistDownloadManager.swift) | 일부 이식 | 파일/HLS 작업 생성, 진행·취소·기존 작업 재연결 | Brave DB·파일 관리자·UA·로깅·background 기본값 제거 또는 대체 |
| [Download.swift](./upstream/ios/brave-ios/Sources/Web/Download.swift) | 일부 이식 | 작업 상태·delegate 구분, 파일명 Bidi 제어문자 제거 | UUID 저장 경로, 제한된 표시 이름, 상태 전이, 빈 pause/resume 메서드 대체 |
| [PlaylistAssetFetcher.swift](./upstream/ios/brave-ios/Sources/Playlist/PlaylistAssetFetcher.swift) | 직접 재사용 가능 후보 | AVURLAsset 로딩 취소용 작은 래퍼 | 필요할 때만 채택; 독립 컴파일·수명 시험 미실행 |
| [PlaylistMimeTypeDetector.swift](./upstream/ios/brave-ios/Sources/Playlist/PlaylistMimeTypeDetector.swift) | 그대로 사용하지 않음 | 일부 MIME/확장자 표와 signature 검사 방식 참고 | 중복 분기·오분류 수정, unknown 명시, 헤더 검사 크기 제한 |
| [DownloadQueue.swift](./upstream/ios/brave-ios/Sources/Brave/Frontend/Browser/DownloadQueue.swift) | 구조 참고 | 시작·진행·완료 이벤트 구분 | 동시 2개 제한·unknown 총량·취소 후 callback 무효화 재작성 |
| [PlaylistScript.js](./upstream/ios/brave-ios/Sources/Brave/Frontend/UserContent/UserScripts/Scripts_Dynamic/Scripts/Paged/PlaylistScript.js) | 후속 단계 참고 | video/audio/source 후보 수집 아이디어 | Brave 전처리기·런타임·prototype 변경에 의존; 원문 주입 금지 |
| [PlaylistScriptHandler.swift](./upstream/ios/brave-ios/Sources/Brave/Frontend/UserContent/UserScripts/Scripts_Dynamic/ScriptHandlers/Paged/PlaylistScriptHandler.swift) | 후속 단계 참고 | JS 메시지→후보 데이터 변환 | 독립 origin/frame/탭/문서 검증과 최소 스키마 필요 |
| [PlaylistTabHelper.swift](./upstream/ios/brave-ios/Sources/Brave/Frontend/Browser/Helpers/PlaylistTabHelper.swift) | 직접 이식 제외 | 메시지 다음 단계의 의존성·사이트 정책 확인 | BraveCore·TabState·DB·Preferences·FeatureList에 직접 연결 |

후속 기능을 보류한 것은 추출 실패가 아니라 첫 버전 범위를 줄이기 위한 결정이다. 영상 후보 탐지는 최초의 직접 파일 다운로드가 정상 동작한 뒤 추가한다.

## 무거운 의존성이 따라오는 이유

원본 [Package.swift](./upstream/ios/brave-ios/Package.swift)의 실제 선언:

```text
Playlist → Data → BraveShared → BraveCore
Playlist → Shared → BraveCore
Playlist → UserAgent → BraveCore
PlaylistCacheLoader → BraveCore / BraveShields
ChromiumDownload → CWVDownloadTask → BraveCore
```

`Shared` 선언은 232행, `BraveShared`는 240행, `Data`는 327행, `UserAgent`는 507행, `Playlist`는 552행이다. 321행은 로컬 `out/ios_current_link/BraveCore.xcframework`를 binary target으로 요구한다. 따라서 Playlist 폴더만 SwiftPM target으로 붙이면 작은 독립 라이브러리가 되지 않는다.

다음은 필요한 대체 경계다.

| Brave 요소 | Stream Browser의 대체 |
|---|---|
| PlaylistInfo / PlaylistItem | 자체 DownloadJob·MediaFile 모델과 repository |
| AsyncFileManager 및 확장 | 전용 저장 루트를 가진 ProtectedFileStore actor |
| UserAgent.mobile / AVAsset.defaultOptions | 공개 API만 사용한 명시적 요청 정책; 기본 UA 우선 |
| Logger.module | URL·파일명·에러 설명을 직접 기록하지 않는 오류 코드 기록 |
| Brave Download / ChromiumDownload | WKDownloadDelegate 어댑터와 자체 작업 상태 |
| 전체 PlaylistUI / PlayerModel | SwiftUI 목록 + 시스템 VideoPlayer/AVPlayer |
| Brave Shields 전체 모듈 | 별도 선정한 규칙 + WKContentRuleListStore |
| 원본 JS 및 TabState 브리지 | 후속 소형 후보 수집기와 네이티브 검증 경계 |

Wallet·Rewards·VPN·Leo·Sync·브라우저 전체 UI·Chromium wrapper는 가져오지 않는다. 위 보호·차단 기능은 이 원본 묶음에 구현되어 있는 것이 아니라 새 앱에서 별도로 구현할 대상이다.

## 원본을 그대로 채택하면 안 되는 구체적 이유

아래는 고정 commit의 선택 파일에서 확인한 이식 관련 사항이다. Brave 제품 전체의 취약점 감사 결과가 아니다.

1. **형식 판별의 도달 불가 분기:** `PlaylistMimeTypeDetector.swift` 50행과 56행이 같은 EBML signature를 비교한다. 첫 분기에서 반환하므로 뒤의 Matroska 분기는 도달하지 못한다. 해당 signature만으로 WebM/MKV를 확정하지 않도록 수정해야 한다.
2. **MP3 계열 signature의 확장자 불일치:** 같은 파일 76~81행에서 `audio/mpeg`를 지정하면서 확장자는 `mp4`다. 148행 이후의 동일 signature 기반 `mp3` 분기는 앞 반환으로 도달하지 못한다. 매핑을 그대로 복사하지 않는다.
3. **unknown을 HLS로 취급하는 기본값:** 같은 파일 176행은 인식하지 못한 데이터에도 HLS MIME을 설정한다. 새 앱은 `unknown`으로 남기고, HLS는 별도의 검증을 거친다.
4. **큐가 동시성 제한 큐는 아님:** `DownloadQueue.swift` 61행은 enqueue마다 즉시 resume한다. 100행에서는 크기 미상 항목을 0으로 더한다. 우리의 동시 전송 제한과 불명확한 총량 표시 요구에 맞지 않아 재작성한다.
5. **다운로드 세션 정책이 다름:** `PlaylistDownloadManager.swift` 79~105행은 3개 background 세션을 만든다. Stream Browser는 공개 파일용과 HLS용 세션을 구성하고 WebKit 인증 다운로드는 해당 탭의 세션에서 처리한다.
6. **기존 모델·로그·헤더 결합:** 매니저의 작업 복원·완료 처리는 `PlaylistItem` DB를 사용하고, 요청에 Range·X-Playback-Session-Id·UserAgent를 붙인다. 새 앱에서는 목적을 확인한 필수 헤더만 보낸다. 오류 설명·모델 debug 출력도 이식하지 않는다.
7. **범용 data-task 경로는 보류:** 매니저 1135행 이후는 `didReceive data`에서 저장과 cached 처리를 한다. 임의 스트리밍 응답을 각 chunk마다 완료 처리하는 구조로 옮기지 않는다. 새 앱의 파일 다운로드는 download task를 우선 사용한다. 기존 경로의 실제 호출 조건 전체까지 검증한 것은 아니다.
8. **JS 단독 실행 불가:** JS에는 `$<...>` 치환 구문, `SECURITY_TOKEN`, `$`, `window.__firefox__` 등 런타임 전제가 있고 HTMLMediaElement 및 setAttribute 동작도 바꾼다. handler의 `.page` world·토큰 검사만 떼어 보호 장치가 완성됐다고 보지 않는다.

검증 대상에 포함한 `DownloadBackgroundTaskScheduler`는 iOS 26+의 BGContinuedProcessingTask와 추가 모듈을 사용한다. 최소 OS가 아직 확정되지 않았고 첫 버전 정책에도 맞지 않아 추출 대상에서 제외했다. `ChromiumDownload` 역시 BraveCore 의존 때문에 제외했다.

## 다음 구현의 최소 구성

아래 파일은 **아직 구현하지 않은** 작업 경계다. 외부 Swift Package 의존성 없이 시작하는 것을 목표로 한다.

```text
BrowserView                 SwiftUI + WKWebView, 비영속 세션
WKDownloadAdapter           WebKit 공식 다운로드 연결, 인증 세션 유지
BackgroundFileDownload      공개 HTTPS 파일 전송, 완료 임시 파일 인수와 작업 재연결
HLSDownload                 AVAssetDownloadURLSession, 시스템 로컬 자산 참조 저장
DownloadCoordinator         큐·상태·취소 generation
ProtectedFileStore          UUID 경로·Complete 보호·원자적 확정·삭제
MediaValidator              제한된 헤더 검사 + AVFoundation 재생 가능성
LibraryView                 저장 목록·삭제·내보내기
LocalPlayer                 AVPlayer 기반 오프라인 재생
```

직접 HTTPS 파일·보호 저장소를 먼저 연결하고 첫 개인 사용판에 공개 파일 백그라운드 전송과 HLS VOD를 포함한다. 공개 파일은 Brave 매니저의 진행·취소·작업 재연결 방식을 참고한다. HLS는 AVAssetDownloadURLSession으로 처리하고, 원본 매니저의 자산 이동 대신 시스템이 지정한 위치의 로컬 참조를 보관한다. 지원 조건과 보호 정책은 [개발 명세서](../../docs/Stream-Browser-iOS-개발명세서-v1.0.md#11-프라이버시와-백그라운드-다운로드의-분리)에 따른다.

파일별 수정 전후와 출처를 기록하고 MPL 고지를 유지한다. 원본의 LICENSE와 각 파일의 헤더를 보존했다. 이번 폴더를 앱 target에 통째로 추가하거나 원본 Package.swift를 resolve하지 않는다.

## 확인한 것과 미확인 사항

확인 완료: 출처 commit 고정, 원본 10개 복사, Git blob 해시 일치, import·Package target 경계, 주요 이식 제외 이유, 문서 링크.

미실행: Swift/Xcode 컴파일, 독립 모듈 추출 후 테스트, iPhone 설치, 영상 다운로드·재생, 실제 저장 파일 보안 검사. 약 122KB는 이번 원본 묶음 크기이며 최종 앱 크기·전체 빌드 용량이 아니다.

재확인 명령: 이 폴더에서 `node verify-upstream.cjs`. 네트워크 접속이나 원본 코드 실행 없이 파일 hash와 경로·심볼릭 링크를 검사한다.
