"""
P0: Unlock all available product features for self-hosted deployment.

Monkey-patches Organization.update_available_product_features() to return
all features defined in AvailableFeature enum, regardless of license status.
"""

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from posthog.models.organization import Organization


def _patched_update_available_product_features(self: "Organization") -> list:
    """Return all features from AvailableFeature enum."""
    from posthog.constants import AvailableFeature

    self.available_product_features = [
        {"key": feature.value, "name": feature.value.replace("_", " ").capitalize()}
        for feature in AvailableFeature
    ]
    return self.available_product_features


def apply() -> None:
    from posthog.models.organization import Organization

    Organization.update_available_product_features = _patched_update_available_product_features  # type: ignore[assignment]
