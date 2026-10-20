#!/bin/zsh
# Copyright (C) 2026 romkas228
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

projectRoot="${0:A:h:h}"
signingDirectory="$projectRoot/.mixer-signing"
identityFile="$signingDirectory/identity.sha1"
pendingIdentityFile="$signingDirectory/pending.sha1"

fail() { print -u2 -- "$*"; exit 1; }

validateFingerprint() {
    [[ ${#1} -eq 40 && "$1" != *[^[:xdigit:]]* ]] \
        || fail "Потрібен SHA-1 відбиток сертифіката: 40 шістнадцяткових символів."
}

requireAvailableIdentity() {
    local fingerprint="$1"
    local identities
    # A self-signed identity need not be a system-trusted root to sign code.
    # Match an exact certificate/private-key identity; codesign then validates the signature.
    identities=$(/usr/bin/security find-identity -p codesigning)
    /usr/bin/awk -v wanted="$fingerprint" \
        'toupper($2) == wanted { found = 1 } END { exit !found }' <<< "$identities" \
        || fail "Сертифікат $fingerprint з приватним ключем недоступний або непридатний для підпису. Тимчасовий підпис не підставляється. Див. docs/SIGNING.md."
}

resolveIdentity() {
    if [[ ! -e "$identityFile" ]]; then
        if [[ -e "$pendingIdentityFile" ]]; then
            local pendingFingerprint="$(< "$pendingIdentityFile")"
            validateFingerprint "$pendingFingerprint"
            fail "Обрано сертифікат ${pendingFingerprint:u}, але доступ до його ключа ще не перевірено. Виконай ./scripts/signing.sh configure ${pendingFingerprint:u} у середовищі з доступом до В’язки ключів. Ad-hoc не підставляється."
        fi
        print -- "-"
        return
    fi
    local fingerprint="$(< "$identityFile")"
    validateFingerprint "$fingerprint"
    fingerprint="${fingerprint:u}"
    requireAvailableIdentity "$fingerprint"
    print -- "$fingerprint"
}

readRequirement() {
    /usr/bin/awk '
        /^(# )?designated => / {
            sub(/^(# )?designated => /, "")
            print
            count++
        }
        END { if (count != 1) exit 1 }
    ' "$1"
}

case "${1:-status}" in
    list)
        /usr/bin/security find-identity -p codesigning
        ;;
    prepare)
        [[ $# -eq 2 ]] || fail "Використання: ./scripts/signing.sh prepare SHA1"
        [[ ! -e "$identityFile" ]] || fail "Постійний підпис уже налаштовано. Для зміни сертифіката використовуй configure."
        fingerprint="${2:u}"
        validateFingerprint "$fingerprint"
        mkdir -p "$signingDirectory"
        pendingIdentity=$(mktemp "$signingDirectory/.pending.XXXXXX")
        trap 'rm -f -- "$pendingIdentity"' EXIT
        print -r -- "$fingerprint" > "$pendingIdentity"
        mv -f "$pendingIdentity" "$pendingIdentityFile"
        print -- "Збережено обраний публічний відбиток $fingerprint. До configure збірка зупинятиметься; ad-hoc не підставляється."
        ;;
    configure)
        [[ $# -eq 2 ]] || fail "Використання: ./scripts/signing.sh configure SHA1"
        fingerprint="${2:u}"
        validateFingerprint "$fingerprint"
        if [[ -e "$pendingIdentityFile" ]]; then
            expectedFingerprint="$(< "$pendingIdentityFile")"
            [[ "$fingerprint" == "${expectedFingerprint:u}" ]] || fail "Відбиток не відповідає підготовленому сертифікату."
        fi
        requireAvailableIdentity "$fingerprint"
        mkdir -p "$signingDirectory"
        pendingIdentity=$(mktemp "$signingDirectory/.identity.XXXXXX")
        trap 'rm -f -- "$pendingIdentity"' EXIT
        print -r -- "$fingerprint" > "$pendingIdentity"
        mv -f "$pendingIdentity" "$identityFile"
        rm -f -- "$pendingIdentityFile"
        print -- "Підпис Mixer закріплено за сертифікатом $fingerprint. Приватний ключ залишається у В’язці ключів."
        ;;
    preflight)
        resolveIdentity
        ;;
    sign)
        [[ $# -eq 3 ]] || fail "Використання: signing.sh sign STAGED_APP EXPECTED_IDENTITY"
        appPath="$2"
        fingerprint=$(resolveIdentity)
        [[ "$fingerprint" == "$3" ]] || fail "Налаштування підпису змінилося під час збірки. Повтори збірку."
        [[ $(/usr/bin/plutil -extract CFBundleIdentifier raw "$appPath/Contents/Info.plist") == "local.mixer.Mixer" ]] \
            || fail "Ідентифікатор Mixer змінився. Підпис не виконано."
        /usr/bin/codesign --force --sign "$fingerprint" --timestamp=none --identifier local.mixer.Mixer "$appPath"
        /usr/bin/codesign --verify --deep --strict --verbose=2 "$appPath"
        if [[ "$fingerprint" == "-" ]]; then
            print -u2 -- "Підпис тимчасовий (ad-hoc): збереження дозволів між різними збірками не гарантовано. Налаштування: docs/SIGNING.md."
            exit 0
        fi

        # Keep the signer-bound default DR. Never replace it with an identifier-only rule.
        requirementsFile="${appPath:h}/requirements.txt"
        /usr/bin/codesign --display --requirements "$requirementsFile" "$appPath"
        requirement=$(readRequirement "$requirementsFile")
        [[ "$requirement" != *cdhash* ]] || fail "Підпис усе ще прив’язаний до конкретної збірки (cdhash). Публікацію скасовано."
        [[ "$requirement" == *certificate* || "$requirement" == *anchor* ]] \
            || fail "Правило ідентичності не перевіряє підписувача. Публікацію скасовано."
        mkdir -p "$signingDirectory"
        baseline="$signingDirectory/$fingerprint.req"
        if [[ -e "$baseline" ]]; then
            /usr/bin/codesign --verify --strict --test-requirement "$baseline" "$appPath"
        else
            pendingRequirement=$(mktemp "$signingDirectory/.requirement.XXXXXX")
            trap 'rm -f -- "$pendingRequirement"' EXIT
            print -r -- "$requirement" > "$pendingRequirement"
            # Check the extracted rule before saving it as the compatibility baseline.
            /usr/bin/codesign --verify --strict --test-requirement "$pendingRequirement" "$appPath"
            mv -f "$pendingRequirement" "$baseline"
        fi
        print -- "Підпис перевірено: ідентичність Mixer відповідає збереженому правилу сертифіката."
        ;;
    verify)
        appPath="${2:-$projectRoot/build/Mixer.app}"
        fingerprint=$(resolveIdentity)
        [[ "$fingerprint" != "-" ]] || fail "Постійний сертифікат ще не налаштовано. Див. docs/SIGNING.md."
        baseline="$signingDirectory/$fingerprint.req"
        [[ -f "$baseline" ]] || fail "Спочатку створи збірку з вибраним сертифікатом."
        /usr/bin/codesign --verify --deep --strict --verbose=2 --test-requirement "$baseline" "$appPath"
        ;;
    status)
        if [[ -e "$identityFile" ]]; then
            print -- "Вибраний сертифікат: $(< "$identityFile")"
        elif [[ -e "$pendingIdentityFile" ]]; then
            print -- "Обрано сертифікат: $(< "$pendingIdentityFile"); очікується configure з доступом до В’язки ключів. Збірка ad-hoc вимкнена."
        else
            print -- "Постійний сертифікат ще не налаштовано; поточний режим — ad-hoc."
        fi
        /usr/bin/security find-identity -p codesigning
        ;;
    *)
        fail "Використання: signing.sh status | list | prepare SHA1 | configure SHA1 | verify [APP]"
        ;;
esac
