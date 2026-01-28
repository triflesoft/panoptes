#!/usr/bin/env python

from ipaddress import ip_network
from jinja2 import FileSystemLoader
from jinja2.sandbox import ImmutableSandboxedEnvironment
from json import load
from os import chmod
from os import makedirs
from os import scandir
from os.path import abspath
from os.path import dirname
from os.path import join
from re import ASCII
from re import compile
from secrets import token_hex
from shutil import copy
from sys import argv


class TemplateProcessor:
    def __init__(self, configuration: dict, source_path: str, destination_path: str):
        self.template_permission_pattern = compile(r"(.*)\.j(\d\d\d)$", ASCII)
        self.raw_data_permission_pattern = compile(r"(.*)\.r(\d\d\d)$", ASCII)
        self.configuration = configuration
        self.source_path = source_path
        self.destination_path = destination_path

        self.environment = ImmutableSandboxedEnvironment(loader=FileSystemLoader([self.source_path]))
        self.environment.globals["configuration"] = self.configuration

    def __process_template(self, template_path: str, destination_path: str, mode: str):
        template = self.environment.get_template(template_path)

        print(destination_path)

        try:
            chmod(destination_path, 0o666)
        except:
            pass

        with open(destination_path, "w") as destination_file:
            destination_file.write(template.render())

        chmod(destination_path, int(mode, 8))

    def __process_raw_data(self, source_path: str, destination_path: str, mode: str):
        print(destination_path)

        try:
            chmod(destination_path, 0o666)
        except:
            pass

        copy(source_path, destination_path)
        chmod(destination_path, int(mode, 8))

    def __enumerate_templates(self, template_path: str, source_path: str, destination_path: str):
        makedirs(destination_path, 0o755, True)

        with scandir(source_path) as dir_iterator:
            for dir_entry in dir_iterator:
                if dir_entry.is_dir():
                    self.__enumerate_templates(join(template_path, dir_entry.name), join(source_path, dir_entry.name), join(destination_path, dir_entry.name))
                elif dir_entry.is_file():
                    match = self.template_permission_pattern.match(dir_entry.name)

                    if match:
                        name = match.group(1)
                        mode = match.group(2)
                        self.__process_template(join(template_path, dir_entry.name), join(destination_path, name), mode)

                    match = self.raw_data_permission_pattern.match(dir_entry.name)

                    if match:
                        name = match.group(1)
                        mode = match.group(2)

                        self.__process_raw_data(join(source_path, dir_entry.name), join(destination_path, name), mode)

    def execute(self):
        self.__enumerate_templates("", self.source_path, self.destination_path)


def enrich_configuration(configuration: dict):
    configuration["password"] = token_hex(32)

    for name, pool in configuration["pools"].items():
        ipn = ip_network(pool["ip_prefix"])
        pool["ip_netmask"] = str(ipn.netmask)
        pool["ip_network"] = str(ipn.network_address)
        pool["ip_lower"] = str(ipn.network_address + 2)
        pool["ip_upper"] = str(ipn.broadcast_address - 2)
        pool["class"] = name.encode("ascii").hex().upper()


def main():
    with open("/etc/panoptes/panoptes.json", "rb") as configuration_file:
        configuration = load(configuration_file)

    enrich_configuration(configuration)

    from pprint import pprint

    pprint(configuration, width=160)

    BASE_PATH = dirname(abspath(__file__))
    TEMPLATES_PATH = join(BASE_PATH, argv[1])

    TemplateProcessor(configuration, TEMPLATES_PATH, "/").execute()


if __name__ == "__main__":
    main()
