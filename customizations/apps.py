from django.apps import AppConfig


class CustomizationsConfig(AppConfig):
    name = "customizations"
    verbose_name = "Custom Modifications"

    def ready(self) -> None:
        from customizations.patches import unlock_features

        unlock_features.apply()
