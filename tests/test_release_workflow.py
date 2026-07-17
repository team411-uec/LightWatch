from pathlib import Path


def test_release_workflow_uploads_dmg_and_zipped_app() -> None:
    workflow = Path(".github/workflows/release.yml").read_text()

    assert '"dist/LightWatch-macOS-${{ steps.version.outputs.value }}.dmg"' in workflow
    assert '"dist/LightWatch-macOS-${{ steps.version.outputs.value }}.zip"' in workflow
