from pathlib import Path
from connexion import FlaskApp
from connexion.options import SwaggerUIOptions


def get_app_instance() -> FlaskApp:
    file_path = Path(__file__).resolve().parent
    swagger_options = SwaggerUIOptions(swagger_ui_path="/docs")
    app = FlaskApp(__name__, specification_dir=file_path / "specification")
    app.add_api(
        "openapi.yaml",
        swagger_ui_options=swagger_options,
        strict_validation=True,
    )
    app.add_api(
        "connectivity_insights.yaml",
        strict_validation=False,
        name="connectivity_insights",
    )
    return app


if __name__ == "__main__":
    app = get_app_instance()
    app.run(host="0.0.0.0", port=8080)
