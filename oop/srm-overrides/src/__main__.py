#!/usr/bin/env python3

import connexion
import logging
import src.encoder as encoder
from json import JSONEncoder

import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    app = connexion.App(__name__, specification_dir='./swagger/')
    app.app.json_encoder = JSONEncoder
    app.add_api(
        'swagger.yaml',
        strict_validation=True,
        arguments={'title': 'Service Resource Manager Controller API'},
        pythonic_params=True,
    )
    app.add_api(
        'connectivity_insights.yaml',
        strict_validation=False,
        arguments={'title': 'Connectivity Insights API'},
        pythonic_params=True,
        base_path='/srm/1.0.0/insights',
    )
    app.add_api(
        'qos_profiles.yaml',
        strict_validation=False,
        arguments={'title': 'QoS Profiles API'},
        pythonic_params=True,
        base_path='/srm/1.0.0',
    )
    app.run(port=8080)


if __name__ == '__main__':
    main()
