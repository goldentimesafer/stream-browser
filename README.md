# Stream Browser

iPhone용 비공개 브라우저 소스입니다. 비공개 웹 탭, 직접 영상 다운로드, 공개 파일 백그라운드 전송, HLS VOD 오프라인 보관을 하나의 저장함에서 처리합니다. 재생은 AVPlayer, 보호 설정은 iOS 데이터 보호와 기기 인증을 사용합니다.

## 빌드와 개인 설치

- **대상 기기**는 iOS 18 이상입니다. SwiftUI, WebKit, Foundation, AVFoundation·AVKit, Photos와 LocalAuthentication을 사용합니다.
- **macOS**에서 `StreamBrowser.xcodeproj`를 열고 `StreamBrowser` 스킴을 선택합니다. Xcode로 기기에 직접 실행하려면 Signing & Capabilities에서 본인 팀을 지정합니다.
- **Windows**에서 준비한 이 프로젝트를 macOS 빌드 환경에서 `bash scripts/build-ios.sh`로 빌드할 수 있습니다. 결과는 `build/StreamBrowser-unsigned.ipa`입니다. 개인 설치 도구로 재서명한 뒤 iPhone에서 설치·실행을 확인합니다.
- GitHub에 이 소스를 올려 사용한다면 Actions의 **iPhone build → Run workflow**에서 수동으로 빌드합니다. 결과물은 `StreamBrowser-unsigned` 아티팩트에 있습니다. 워크플로는 서명 자격 증명이나 Apple 계정 비밀번호를 요구하지 않습니다. [GitHub 실행 환경](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- 개인 설치와 갱신 절차는 [Windows + iPhone 개인 설치 명세](docs/Stream-Browser-개인설치-변경명세-v1.1.md)를 참고합니다.

## 첫 실행과 영상 저장

1. iPhone의 Face ID 또는 기기 암호로 앱 잠금을 해제합니다.
2. 탐색에서 주소를 열거나 아래쪽 **영상 저장** 버튼으로 직접 HTTPS 영상 주소를 입력합니다.
3. **비공개 전경 저장**은 WebKit을 사용합니다. 백그라운드 파일과 HLS를 저장하려면 먼저 **설정 → 공개 다운로드 출처**에서 직접 관리하거나 신뢰하는 공개 호스트를 등록합니다. HLS가 별도 CDN의 목록이나 세그먼트를 사용하면 해당 호스트도 등록합니다.
4. 저장 방식과 권한 확인을 선택하고 **저장 시작**을 누릅니다. 공개 시스템 전송은 셀룰러 데이터를 사용하지 않으며, iOS가 시작 시점을 조정할 수 있습니다. 강제 종료 후에는 앱을 다시 열어 작업 상태를 확인합니다.
5. **저장함**에서 완료한 영상을 열어 오프라인으로 재생합니다. 일반 영상은 길게 눌러 파일 앱·사진 앱에 사본을 저장할 수 있습니다. HLS는 시스템이 제공한 위치의 자산을 앱에서 재생하고 삭제합니다.

## 구현 범위와 확인할 항목

- 초기 일반 영상 지원 대상은 MP4·MOV·M4V입니다. 파일 헤더와 기기 재생 가능 여부를 확인합니다.
- HLS는 등록된 HTTPS 출처의 비암호화 VOD를 처리합니다. 라이브, 암호화, 토큰 쿼리, 동적 URL 치환과 지원 목록 밖의 태그를 거부합니다. 초기 목록 검사는 시스템 엔진이 이후에 수행하는 각 요청을 가로채는 방식과 다릅니다. 공개 전송에는 검증된 공급원을 사용합니다. [Apple HLS 예제](https://developer.apple.com/documentation/avfoundation/using-avfoundation-to-play-and-persist-http-live-streams) · [백그라운드 리디렉션](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:))
- HLS 저장 전 최대 화질과 한국어·영어·일본어 오디오/자막을 선택할 수 있습니다. 제공되지 않는 언어는 시작 전에 안내합니다. 저장된 트랙은 재생 화면에서 선택합니다. 잠금 중 재생 차단과 HLS 패키지의 파일 보호는 실기기에서 확인해야 합니다.
- 앱 탭·쿠키와 직접 링크는 브라우저 세션에 보관합니다. 공개 시스템 작업을 복구하기 위한 최소 로컬 기록과 다운로드된 영상은 기기에 남습니다. 기본 검색어는 제출할 때 DuckDuckGo로 전송됩니다.
- 사이트 차단은 코드에 포함된 소수의 추적·광고 도메인부터 적용합니다. 보유 iPhone에서 차단 규칙 적용과 사이트 호환성을 확인합니다.

`bash scripts/build-ios.sh`는 순수 Swift 정책 검사, 실제 파일을 사용하는 저장 복구 검사와 iPhone용 빌드를 수행합니다. [v1.3 변경·검증 안내](docs/Stream-Browser-수정검증-v1.3.md)에 복구 기능, 일시정지, 영상 감지와 제약을 정리했습니다. 실기기에서는 직접 저장, 화면 잠금 중 공개 전송, 강제 종료 후 상태, 비행기 모드 HLS·MP4 재생, 내보내기, 삭제를 확인합니다. 전체 인수 조건은 [검증 계획](docs/Stream-Browser-검증계획-v1.0.md)에 있습니다.

이 소스는 Windows에서 개발합니다. 빌드 결과는 해당 커밋의 GitHub Actions에서 확인하며, iPhone 설치·다운로드·재생·데이터 보호는 별도 실기기 검증이 필요합니다.
