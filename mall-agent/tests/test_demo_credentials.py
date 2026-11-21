import pytest

from scripts import demo_credentials


@pytest.fixture(autouse=True)
def isolated_demo_config(tmp_path, monkeypatch):
    for var in ("MALL_DEMO_ADMIN_PASSWORD", "MALL_DEMO_MEMBER_PASSWORD", "MALL_DEMO_PASSWORD"):
        monkeypatch.delenv(var, raising=False)
    config = tmp_path / "secrets.json"
    monkeypatch.setattr(demo_credentials, "_LOCAL_CONFIG", config)
    return config


def test_private_config_is_used_for_both_roles(isolated_demo_config):
    isolated_demo_config.write_text('{"demoPassword": "local fixture"}', encoding="utf-8")
    assert demo_credentials.demo_password("staff") == "local fixture"
    assert demo_credentials.demo_password("member") == "local fixture"


def test_explicit_staff_and_member_values_override_local_config(isolated_demo_config, monkeypatch):
    isolated_demo_config.write_text('{"demoPassword": "local fixture"}', encoding="utf-8")
    monkeypatch.setenv("MALL_DEMO_ADMIN_PASSWORD", "staff fixture")
    monkeypatch.setenv("MALL_DEMO_MEMBER_PASSWORD", "member fixture")
    monkeypatch.setenv("MALL_DEMO_PASSWORD", "legacy member fixture")
    assert demo_credentials.demo_password("staff") == "staff fixture"
    assert demo_credentials.demo_password("member") == "member fixture"


def test_legacy_member_environment_override_still_works(monkeypatch):
    monkeypatch.setenv("MALL_DEMO_PASSWORD", "legacy member fixture")
    assert demo_credentials.demo_password("member") == "legacy member fixture"


def test_missing_config_fails_without_falling_back_to_a_password():
    with pytest.raises(RuntimeError, match="Set MALL_DEMO_MEMBER_PASSWORD"):
        demo_credentials.demo_password("member")


def test_malformed_config_error_does_not_repeat_its_contents(isolated_demo_config):
    isolated_demo_config.write_text("not JSON; arbitrary sensitive payload", encoding="utf-8")
    with pytest.raises(RuntimeError, match="Unable to read the private") as error:
        demo_credentials.demo_password("staff")
    assert "arbitrary sensitive payload" not in str(error.value)
