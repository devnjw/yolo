# FocusTrace 배포

공유 링크: https://github.com/devnjw/yolo/releases/latest

공개 Release의 DMG는 GitHub 로그인 없이 받을 수 있습니다. Release에 검증한 DMG와 `.dmg.sha256`을 함께 올리고, 설치·실행 권한 안내와 공증 여부를 본문에 명시합니다. 새 버전은 새 태그와 새 파일명으로 게시하며 이전 버전 파일을 덮어쓰지 않습니다. 공개 Release는 CI artifact와 달리 14일 보관 기간의 영향을 받지 않습니다.

## 기본 공유 빌드

macOS에서 Swift 6 이상과 macOS SDK를 준비하고 다음을 실행합니다.

```sh
swift test
zsh scripts/package.sh
```

`dist/FocusTrace-<version>-<build>-universal.dmg` 하나를 전달합니다. DMG는 읽기 전용 압축 이미지이며 앱, Applications 바로가기, 설치 안내, 공증 여부만 포함합니다. 소스·기록·백업·로컬 설정을 패키징하지 않습니다. 개발용 `dist/FocusTrace.app` 대신 `dist/universal/FocusTrace.app`을 빌드합니다. 버전과 빌드번호는 `Resources/Info.plist`에서 관리하며 새 버전을 공유하기 전에 올리세요.

기본 빌드는 ad-hoc 서명입니다. 코드 서명 검증 성공은 Apple의 Developer ID 인증이나 공증을 의미하지 않습니다. 다운로드한 파일에는 Gatekeeper 경고가 발생할 수 있습니다. 받는 사람이 할 일은 [설치 안내](INSTALL.txt)에 설명되어 있습니다.

체크섬은 최종 DMG를 기준으로 생성합니다. 같은 폴더에서 다음으로 확인할 수 있습니다.

```sh
shasum -a 256 -c FocusTrace-0.2.0-18-universal.dmg.sha256
```

체크섬은 파일 전송 중 변경 여부를 확인하는 용도이며 보낸 사람의 신원을 인증하지 않습니다.

## Developer ID 서명과 Apple 공증

보안 경고 없이 배포하는 경로에는 Apple Developer Program의 Developer ID Application 인증서와 Apple 공증이 필요합니다. 인증서는 빌드 Mac의 Keychain에 설치하고 공증 자격 증명은 `xcrun notarytool store-credentials`로 Keychain에 저장하세요. 비밀번호·인증서 개인 키를 저장소나 채팅에 넣지 않습니다.

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='focustrace-notary' \
zsh scripts/package.sh
```

스크립트는 hardened runtime·타임스탬프로 앱을 서명하고, 앱 ZIP 제출 → 앱 ticket staple·검증 → Gatekeeper 평가 → DMG 생성·서명 → DMG 제출·staple·검증 순으로 실행합니다. 공증이나 검증이 실패하면 최종 DMG를 교체하지 않습니다. `NOTARY_PROFILE` 없이 `SIGNING_IDENTITY`만 지정하면 서명만 하며 공증된 것으로 표시하지 않습니다.

GitHub Actions는 인증서나 공증 자격 증명을 사용하지 않으며 ad-hoc 빌드만 생성합니다. 이 저장소의 기본 설정으로는 공증을 완료할 수 없습니다. Apple Developer 자격 증명을 준비한 Mac에서 위 명령을 실행하세요.

공식 절차: [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## 전달 전 확인

- 테스트 통과, universal 실행 파일의 arm64·x86_64 슬라이스와 서명 검증 성공.
- DMG를 열어 앱과 Applications 바로가기, 설치 안내가 있는지 확인.
- 별도 Mac/새 사용자 계정에서 응용 프로그램으로 복사한 뒤 첫 실행·자동화 허용·사이트 기록·로그인 자동 실행 확인.
- 업데이트는 앱을 종료한 뒤 교체하고 기록이 유지되는지 확인. bundle ID는 기존 `local.jinwoo.FocusTrace`를 유지합니다.

패키징 자동 검증은 실제 Intel 하드웨어나 macOS 13에서의 실행, 다운로드 격리 속성이 있는 앱의 첫 실행, macOS 자동화 권한 UI를 대신하지 않습니다.
