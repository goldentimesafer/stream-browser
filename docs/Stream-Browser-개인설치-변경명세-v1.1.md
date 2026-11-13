# Stream Browser — Windows + 개인 iPhone 변경 명세 v1.1

작성일: 2026-11-13

## 확정 조건과 적용 순서

사용자는 Windows PC와 iPhone을 보유하며 본인 기기에만 앱을 설치한다. App Store 공개 배포는 현재 범위가 아니다. 이 문서는 [v1.0 개발 명세서](./Stream-Browser-iOS-개발명세서-v1.0.md)의 배포·개발 환경·출시 조건보다 우선한다. 브라우저·다운로드·프라이버시·저장소 보안 요구사항은 유지한다.

## 제안 개발·설치 경로

1. Windows에서 Swift 소스·프로젝트 설정·시험 fixture를 작성한다.
2. macOS 빌드 환경에서 Xcode로 iPhone 기기용 바이너리를 만든다. GitHub Actions의 macOS runner 또는 신뢰하는 원격 Mac을 후보로 둔다.
3. 개인 설치 도구가 처리할 수 있는 IPA로 패키징한다. 기기용 arm64 빌드를 사용하며 시뮬레이터 빌드는 설치 결과물로 사용하지 않는다.
4. Windows의 AltServer와 iPhone의 AltStore Classic을 통해 개인 Apple 계정으로 재서명·설치한다.
5. 무료 서명 유효 기간 내 갱신한다. 자동 갱신은 PC 연결·실행 상태 등에 영향을 받으므로 수동 갱신 경로도 시험한다.

이 조합은 권장 후보이며 실제 설치 성공을 확인한 것은 아니다. 앱의 entitlement와 재서명 지원 여부를 확인하기 위해, 브라우저 전체를 만들기 전에 빈 WKWebView 앱으로 빌드→패키징→설치→업데이트→갱신을 검증한다. 기기 암호·Developer Mode·컴퓨터 신뢰 설정은 사용자가 직접 확인한다.

GitHub는 macOS hosted runner를 제공한다. 비공개 저장소의 실행은 계정에 포함된 사용량을 소비하며 초과 비용이 발생할 수 있다. 이 문서 작성으로 저장소 업로드나 유료 실행을 시작하지 않는다. [GitHub 공식 문서](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

AltStore Classic은 Windows 설치 경로를 제공하며, 무료 계정 앱은 7일 후 만료된다. AltServer가 실행 중인 PC와 USB 또는 같은 Wi-Fi로 연결하여 갱신할 수 있다. [Windows 설치](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) · [갱신과 만료](https://faq.altstore.io/altstore-classic/your-altstore) · [AltServer 연결](https://faq.altstore.io/altstore-classic/altserver)

## v1.0에서 변경하는 사항

| 기존 | 개인용 변경 |
|---|---|
| App Store 공개 배포 | 본인 iPhone 개인 설치 |
| Mac 구매 또는 로컬 Mac 확보 | 클라우드/원격 macOS 빌드 후보; Windows에서 소스 작성 |
| 심사 승인·스토어 설명·심사용 콘텐츠 | 현재 완료 조건에서 제외; 공개 배포로 바꿀 때 복원 |
| TestFlight 배포 | 첫 경로에서 제외 |
| 여러 iPhone·OS의 출시 검증 | 보유 기기·iOS 실기기 검증 우선; 다른 기기 지원 보장 없음 |
| 제출 SDK 요구 중심 | 보유 iOS와 호환되는 정식 Xcode/SDK 및 설치 도구 조합 검증 |
| W10 제출 | W10 개인 설치·갱신·업데이트·데이터 유지 검증 |

App Store 심사 대응을 현재 기능 제한의 근거로 삼지 않는다. 다만 개인 설치만으로 iOS API·샌드박스·백그라운드 제약이나 DRM이 없어지는 것은 아니다. 콘텐츠 다운로드의 구체적 지원 범위는 실제 대상과 기술 검증에 따라 별도로 결정하며, 이번 변경만으로 특정 서비스 추출기나 DRM 우회 기능을 추가하지 않는다.

## 빌드 과정의 프라이버시

- 앱 실행 데이터와 빌드 데이터를 구분한다. 클라우드 빌드를 사용하면 해당 서비스에 소스와 빌드 로그가 전달된다. 사용자의 방문 기록·영상·쿠키는 빌드에 필요하지 않다.
- Apple 계정 비밀번호·2단계 인증 코드·기기 pairing 파일을 채팅, 저장소, 일반 CI 변수·로그에 넣지 않는다.
- 후보 구성은 CI에서 사용자 Apple 비밀번호 없이 컴파일·패키징하고, 개인 서명은 설치 도구가 로컬에서 처리하는 흐름이다. 실제 가능 여부는 초기 스파이크로 확인한다.
- 의존성·CI action은 버전 또는 commit을 고정하고 설치 파일은 공식 배포처에서 받는다.
- CI artifact의 접근 범위·보존 기간을 제한하고 소스 commit과 결과물 해시를 기록한다.
- 서명 갱신은 방문 기록 삭제·앱 초기화와 다른 작업이다. 갱신 과정에서 앱 데이터를 유지하는지 실기기로 확인한다.

## 추가 인수시험

| ID | 절차 | 합격 기준 |
|---|---|---|
| D01 | 빈 WKWebView 앱 클라우드 빌드·Windows 설치 | 보유 iPhone에서 정상 실행 |
| D02 | 동일 앱 ID·계정으로 새 버전 설치 | 기존 저장 영상·설정 유지, 스키마 정상 |
| D03 | 서명 만료 전 수동 갱신 | 실행 가능 기간 갱신, 앱 데이터 유지 |
| D04 | PC 부재·갱신 실패·만료 후 복구 | 원인과 복구 절차 재현; 앱 삭제를 기본 해결책으로 쓰지 않음 |
| D05 | 재서명 후 entitlement·보호 파일 검사 | Data Protection·앱 잠금·Keychain 동작이 보안 요구와 일치 |
| D06 | CI 로그·artifact·저장소 검사 | Apple 비밀번호·쿠키·개인 영상·pairing 파일 없음 |
| D07 | iOS 업데이트 후 설치·갱신·실행 | 지원 조합 재검증, 변경된 신뢰·개발자 설정 확인 |

기존 49개 시험 중 보안·삭제·다운로드 시험은 계속 적용한다. App Store 제출 관련 증거는 현재 필수가 아니다. 설치 도구 자체가 서드파티 소프트웨어라는 점을 고려해 공식 안내·계정 처리·지원 iOS를 설치 전에 확인한다.

## 구현 착수 전에 확인할 정보

- iPhone 모델과 iOS 버전.
- 무료 계정의 주기적 갱신을 사용할지 여부.
- 사용할 비공개 저장소·클라우드 macOS 빌드 서비스와 사용량 한도.

Mac 구매나 유료 개발자 가입을 선행 필수 조건으로 두지 않는다. 클라우드 빌드·개인 서명의 실제 호환성을 먼저 확인하고 선택한다.
