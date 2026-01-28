#!/usr/bin/env python

from collections import defaultdict
from dataclasses import dataclass
from gzip import GzipFile
from ipaddress import _BaseNetwork
from ipaddress import collapse_addresses
from ipaddress import ip_network
from ipaddress import IPv4Address
from ipaddress import IPv6Network
from ipaddress import summarize_address_range
from json import dump
from json import load
from os import makedirs
from os import rename
from os import SEEK_CUR
from os import SEEK_END
from os import SEEK_SET
from os.path import abspath
from os.path import dirname
from os.path import isfile
from os.path import join
from requests import request
from secrets import token_hex


@dataclass
class IPRange:
    string_lower: str
    string_upper: str
    number_lower: int
    number_upper: int


def format_size(value: int):
    for unit in ("", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB", "ZiB"):
        if abs(value) < 1024.0:
            return f"{value:3.1f}{unit}"

        value /= 1024.0

    return f"{value:.1f}YiB"


def compact_ip_ranges(ip_ranges: list[IPRange]) -> list[IPRange]:
    for try_index in range(10):
        ip_ranges = sorted(ip_ranges, key=lambda r: (r.number_lower, r.number_upper))

        if len(ip_ranges) == 0:
            return ip_ranges

        result = [ip_ranges[0]]
        prev_ip_range = ip_ranges[0]

        for next_ip_range in ip_ranges[1:]:
            if prev_ip_range.number_upper + 1 == next_ip_range.number_lower:
                prev_ip_range.number_upper = next_ip_range.number_upper
                prev_ip_range.string_upper = next_ip_range.string_upper
            else:
                result.append(next_ip_range)
                prev_ip_range = next_ip_range

        ip_ranges = result
        result = [ip_ranges[0]]
        prev_ip_range = ip_ranges[0]

        for next_ip_range in ip_ranges[1:]:
            if (prev_ip_range.number_lower <= next_ip_range.number_lower) and (prev_ip_range.number_upper >= next_ip_range.number_upper):
                pass
            elif (next_ip_range.number_lower <= prev_ip_range.number_lower) and (next_ip_range.number_upper >= prev_ip_range.number_upper):
                result[-1] = next_ip_range
                prev_ip_range = next_ip_range
            else:
                result.append(next_ip_range)
                prev_ip_range = next_ip_range

    return ip_ranges


def convert_ipv4_ranges(ip_ranges: list[IPRange]) -> list[_BaseNetwork]:
    ip_networks = []

    for ip_range in ip_ranges:
        number_lower = ip_range.number_lower
        number_upper = ip_range.number_upper

        ip_networks.extend(summarize_address_range(IPv4Address(number_lower), IPv4Address(number_upper)))

    ip_networks = list(collapse_addresses(ip_networks))

    for a in ip_networks:
        for b in ip_networks:
            if a != b and a.overlaps(b):
                print(a, b)

    return list(collapse_addresses(ip_networks))


class RipeDatabaseProcessor:
    def __init__(self, configuration: dict, source_path: str):
        self.configuration = configuration
        self.source_path = source_path
        self.ripe_database_url = "https://ftp.ripe.net/ripe/dbase/ripe.db.gz"
        self.ripe_path = "/tmp/ripedb"
        makedirs(self.ripe_path, 0o755, True)
        self.ripe_database_file_path = join(self.ripe_path, "ripe.db.gz")
        self.ripe_database_temp_path = join(self.ripe_path, "~ripe.db.gz")
        self.ripe_catalog_file_path = join(self.ripe_path, "~ripe.json")

    def download(self):
        if not isfile(self.ripe_database_file_path):
            print("Downloading RIPE database...", end="")

            with request("GET", self.ripe_database_url, stream=True) as response:
                content_length = int(response.headers.get("Content-Length", "0"))

                with open(self.ripe_database_temp_path, mode="wb") as file:
                    read_length = 0

                    for chunk in response.iter_content(512 * 1024):
                        file.write(chunk)
                        read_length += len(chunk)
                        read_percent = 100 * read_length // content_length
                        print(f"\r\033[KDownloading RIPE database... {read_percent}% ({format_size(read_length)}/{format_size(content_length)})", end="")

            print("\r\033[KDownloading RIPE database... done")
            print("Saving database... ", end="", flush=True)
            rename(self.ripe_database_temp_path, self.ripe_database_file_path)
            print("\r\033[KSaving database... done")

    def parse(self):
        line_index = 0
        catalog = defaultdict(lambda: defaultdict(list))

        with open(self.ripe_database_file_path, "rb") as ripe_gzip_file:
            ripe_gzip_file.seek(0, SEEK_END)
            content_length = ripe_gzip_file.tell()
            ripe_gzip_file.seek(0, SEEK_SET)

            with GzipFile(fileobj=ripe_gzip_file, mode="r") as ripe_gzip:
                obj = defaultdict(list)
                attr_name = ""
                attr_value = ""
                line = "\n"

                print("Parsing RIPE database...", end="")

                while True:
                    try:
                        line = ripe_gzip.readline(64 * 1024).decode("latin-1")
                        line_index += 1

                        if len(line) == 0:
                            break

                        if line_index % 1000 == 0:
                            read_length = ripe_gzip_file.tell()
                            read_percent = 100 * read_length // content_length
                            print(f"\r\033[KParsing RIPE database... {read_percent}% ({format_size(read_length)}/{format_size(content_length)})", end="")

                        if line.startswith(" ") or line.startswith("+"):
                            attr_value += line.strip()
                        else:
                            obj[attr_name].append(attr_value)

                            if line.startswith("#"):
                                continue

                            if line == "\n":
                                inetnum4 = obj.get("inetnum")

                                if inetnum4 != None:
                                    country = obj.get("country")

                                    if country and (len(country) == 1):
                                        country = country[0].split("#")[0].strip().upper()
                                        catalog[country]["ipv4"].append(inetnum4[0].split(" - "))

                                inetnum6 = obj.get("inet6num")

                                if inetnum6 != None:
                                    country = obj.get("country")

                                    if country and (len(country) == 1):
                                        country = country[0].split("#")[0].strip().upper()
                                        catalog[country]["ipv6"].append(inetnum6[0])

                                obj = defaultdict(list)
                            else:
                                attr_name, attr_value = line.split(":", 1)
                                attr_name = attr_name.strip()
                                attr_value = attr_value.strip()
                    except Exception as e:
                        print(line_index, line, e)

            print("\r\033[KParsing RIPE database... done")
            print("Saving catalog... ", end="", flush=True)

            with open(self.ripe_catalog_file_path, "w") as catalog_file:
                dump(catalog, catalog_file, indent=2)

            print("\r\033[KSaving catalog... done")

    def build(self):
        allowed_country_codes = set(self.configuration["network"]["external"]["firewall"]["allow_countries"])
        all_ipv4_ranges = []
        all_ipv6_networks = []

        print("Loading catalog... ", end="", flush=True)

        with open(self.ripe_catalog_file_path, "r") as catalog_file:
            catalog = load(catalog_file)

        print("\r\033[KLoading catalog... done", flush=True)

        for country_code, country_data in catalog.items():
            if country_code not in allowed_country_codes:
                print(f"Ignoring country {country_code}.", flush=True)
                continue

            print(f"Processing country {country_code}... ", end="", flush=True)
            ipv4_pairs = country_data.get("ipv4", [])
            ipv6_cidrs = country_data.get("ipv6", [])

            print("IPv4... ", end="", flush=True)

            for ipv4_pair in sorted(ipv4_pairs):
                ipv4_lower = IPv4Address(ipv4_pair[0])
                ipv4_upper = IPv4Address(ipv4_pair[1])
                ipv4_number_lower = int.from_bytes(ipv4_lower.packed, byteorder="big", signed=False)
                ipv4_number_upper = int.from_bytes(ipv4_upper.packed, byteorder="big", signed=False)
                all_ipv4_ranges.append(
                    IPRange(
                        str(ipv4_lower),
                        str(ipv4_upper),
                        ipv4_number_lower,
                        ipv4_number_upper,
                    )
                )

            print("IPv6... ", end="", flush=True)

            all_ipv6_networks.extend(list(IPv6Network(ipv6_cidr) for ipv6_cidr in ipv6_cidrs))

            print("\r\033[KProcessing country {country_code}... done", flush=True)

        print("Compacting IP ranges... ", end="", flush=True)

        all_ipv4_ranges = compact_ip_ranges(all_ipv4_ranges)

        print("\r\033[KCompacting IP ranges... done", flush=True)
        print("Converting IP ranges... ", end="", flush=True)

        self.ipv4_networks = convert_ipv4_ranges(all_ipv4_ranges)

        print("\r\033[KConverting IP ranges... done", flush=True)
        print("Collapsing IP addresses... ", end="", flush=True)

        self.ipv6_networks = list(collapse_addresses(all_ipv6_networks))

        print("\r\033[KCollapsing IP addresses... done", flush=True)

        print("Saving NT tables configuration... ", end="", flush=True)

        with open(join(self.source_path, "etc/sysconfig/nftables-geoip-ipv4.nft.r440"), "wb") as nftables_ipv4_config_file:
            with open(join(self.source_path, "etc/sysconfig/nftables-geoip-ipv6.nft.r440"), "wb") as nftables_ipv6_config_file:
                nftables_ipv4_config_file.write(b"set geoip_subnets_v4 {\n")
                nftables_ipv4_config_file.write(b"    type ipv4_addr;\n")
                nftables_ipv4_config_file.write(b"    flags interval;\n\n")
                nftables_ipv4_config_file.write(b"    elements = {\n")

                nftables_ipv6_config_file.write(b"set geoip_subnets_v6 {\n")
                nftables_ipv6_config_file.write(b"    type ipv6_addr;\n")
                nftables_ipv6_config_file.write(b"    flags interval;\n\n")
                nftables_ipv6_config_file.write(b"    elements = {\n")

                if len(self.ipv4_networks) > 0:
                    for ipv4_network in self.ipv4_networks:
                        nftables_ipv4_config_file.write(f"        {str(ipv4_network)},\n".encode("ascii"))

                if len(self.ipv6_networks) > 0:
                    for ipv6_network in self.ipv6_networks:
                        nftables_ipv6_config_file.write(f"        {str(ipv6_network)},\n".encode("ascii"))

                nftables_ipv4_config_file.seek(-2, SEEK_CUR)
                nftables_ipv4_config_file.write(b"\n")
                nftables_ipv4_config_file.write(b"    }\n")
                nftables_ipv4_config_file.write(b"}\n")

                nftables_ipv6_config_file.seek(-2, SEEK_CUR)
                nftables_ipv6_config_file.write(b"\n")
                nftables_ipv6_config_file.write(b"    }\n")
                nftables_ipv6_config_file.write(b"}\n")

        print("\r\033[KSaving NT tables configuration... done", flush=True)

    def execute(self):
        self.download()
        self.parse()
        self.build()


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
    with open("/home/roman/Documents/panoptes/xpanding.json", "rb") as configuration_file:
        # with open("/etc/panoptes/panoptes.json", "rb") as configuration_file:
        configuration = load(configuration_file)

    enrich_configuration(configuration)

    from pprint import pprint

    pprint(configuration, width=160)

    BASE_PATH = dirname(abspath(__file__))
    TEMPLATES_PATH = join(BASE_PATH, "templates")

    RipeDatabaseProcessor(configuration, TEMPLATES_PATH).execute()


if __name__ == "__main__":
    main()
