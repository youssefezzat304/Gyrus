#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
check_dir="${GYRUS_CHECK_OUTPUT:-/tmp/GyrusChecks}"
mkdir -p "$check_dir"
xcrun swiftc -O -parse-as-library \
    Sources/Gyrus/UI/DesignSystem/VisualConfiguration.swift Sources/Gyrus/Core/Brain/BrainMath.swift Sources/Gyrus/Services/Rendering/BrainParticleGenerator.swift \
    Sources/Gyrus/Core/Brain/CameraController.swift Sources/Gyrus/Services/Rendering/BrainRenderer.swift Sources/Gyrus/UI/Brain/BrainView.swift Tests/PrototypeChecks.swift \
    Sources/Gyrus/Core/Topics/Topic.swift Sources/Gyrus/Services/Topics/TopicStore.swift Sources/Gyrus/UI/Brain/BrainSession.swift \
    -o "$check_dir/prototype-checks"
"$check_dir/prototype-checks"
