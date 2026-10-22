"""Development entry point for the standalone Foundry weather agent."""

from __future__ import annotations

from dotenv import load_dotenv

from weather_agent.config import AppConfig, ConfigurationError
from weather_agent.web import create_app


def main() -> None:
    load_dotenv(override=False)
    try:
        config = AppConfig.from_env()
        app = create_app(config)
    except (ConfigurationError, RuntimeError, ValueError) as error:
        raise SystemExit(f"Startup error: {error}") from error
    app.run(
        host=config.flask_host,
        port=config.flask_port,
        debug=False,
        use_reloader=False,
        threaded=True,
    )


if __name__ == "__main__":
    main()
