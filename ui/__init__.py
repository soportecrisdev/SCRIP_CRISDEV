"""
CRISDEV VPN Manager - UI Package
"""
from ui.theme import (
    C_OK, C_ERROR, C_WARN, C_INFO, C_DIM, C_BOLD, C_ACCENT, C_PROMPT, C_RESET
)
from ui.components import (
    bold, ok, error, warn, info, dim,
    clear_screen, header, banner_welcome, dashboard,
    section, separator, menu_item, menu_item_right, two_col_menu,
    prompt_input, confirm_destructive, breadcrumb, pause,
    ok_msg, error_msg, info_msg, warn_msg,
    user_table, user_detail_card, service_status_table,
    get_user_stats, check_service_status, check_service_latency,
    get_server_ip, get_server_os, get_uptime,
)
