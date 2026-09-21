<?php
/**
 * Plugin Name: Site Revenue Calculator
 * Plugin URI: https://github.com/skyboy610/reality-consolidate
 * Description: محاسبه دقیق درآمد سایت بر اساس بازه هفتگی، ماهانه و تاریخ دلخواه شمسی، همراه با تفکیک کامل مبالغ و تعداد تراکنش‌ها.
 * Version: 1.1.0
 * Requires at least: 5.6
 * Requires PHP: 7.4
 * Author: Digital Team
 * License: GPL-2.0-or-later
 * License URI: https://www.gnu.org/licenses/gpl-2.0.html
 * Text Domain: site-revenue-calculator
 * Domain Path: /languages
 * WC requires at least: 5.0
 * WC tested up to: 9.9
 */

defined( 'ABSPATH' ) || exit;

define( 'SREVC_VERSION', '1.1.0' );
define( 'SREVC_FILE', __FILE__ );
define( 'SREVC_PATH', plugin_dir_path( __FILE__ ) );
define( 'SREVC_URL', plugin_dir_url( __FILE__ ) );
define( 'SREVC_OPTION', 'srevc_settings' );
define( 'SREVC_CAPABILITY', 'manage_woocommerce' );

require_once SREVC_PATH . 'includes/class-srevc-jalali.php';
require_once SREVC_PATH . 'includes/class-srevc-format.php';
require_once SREVC_PATH . 'includes/class-srevc-range.php';
require_once SREVC_PATH . 'includes/class-srevc-query.php';
require_once SREVC_PATH . 'includes/class-srevc-cleanup.php';
require_once SREVC_PATH . 'includes/class-srevc-settings.php';
require_once SREVC_PATH . 'includes/class-srevc-admin.php';

function srevc_default_settings() {
	return array(
		'statuses'               => array( 'wc-completed', 'wc-processing' ),
		'exclude_via'            => array(),
		'manual_via'             => 'admin',
		'cleanup_window'         => 3,
		'exclude_zero'           => 1,
		'wallet_keywords'        => 'کیف پول, شارژ حساب',
		'wallet_products'        => '',
		'wallet_gateways'        => 'wallet',
		'exclude_wallet_payment' => 0,
		'divide_by_ten'          => 0,
		'persian_digits'         => 1,
		'currency_label'         => 'تومان',
		'default_range'          => 'month',
	);
}

function srevc_get_settings() {
	$saved = get_option( SREVC_OPTION, array() );
	if ( ! is_array( $saved ) ) {
		$saved = array();
	}
	return wp_parse_args( $saved, srevc_default_settings() );
}

function srevc_user_can() {
	return current_user_can( SREVC_CAPABILITY ) || current_user_can( 'manage_options' );
}

function srevc_woocommerce_active() {
	return class_exists( 'WooCommerce' ) && function_exists( 'wc_get_order_statuses' );
}

function srevc_activate() {
	if ( false === get_option( SREVC_OPTION, false ) ) {
		add_option( SREVC_OPTION, srevc_default_settings() );
	}
	srevc_maybe_upgrade();
}

function srevc_maybe_upgrade() {
	$stored = get_option( 'srevc_version', '1.0.0' );
	if ( version_compare( $stored, SREVC_VERSION, '>=' ) ) {
		return;
	}

	$settings = srevc_get_settings();

	if ( version_compare( $stored, '1.1.0', '<' ) ) {
		$settings['exclude_via'] = array_values( array_diff( (array) $settings['exclude_via'], array( 'admin' ) ) );
		if ( empty( $settings['manual_via'] ) ) {
			$settings['manual_via'] = 'admin';
		}
		if ( empty( $settings['cleanup_window'] ) ) {
			$settings['cleanup_window'] = 3;
		}
	}

	update_option( SREVC_OPTION, $settings );
	update_option( 'srevc_version', SREVC_VERSION );
}
register_activation_hook( SREVC_FILE, 'srevc_activate' );

function srevc_deactivate() {
	delete_transient( 'srevc_last_report' );
}
register_deactivation_hook( SREVC_FILE, 'srevc_deactivate' );

function srevc_declare_hpos_compatibility() {
	if ( class_exists( '\Automattic\WooCommerce\Utilities\FeaturesUtil' ) ) {
		\Automattic\WooCommerce\Utilities\FeaturesUtil::declare_compatibility( 'custom_order_tables', SREVC_FILE, true );
	}
}
add_action( 'before_woocommerce_init', 'srevc_declare_hpos_compatibility' );

function srevc_missing_woocommerce_notice() {
	if ( srevc_woocommerce_active() || ! srevc_user_can() ) {
		return;
	}
	echo '<div class="notice notice-error"><p class="srevc-inline-error">' . esc_html__( 'افزونه محاسبه درآمد سایت برای کار کردن به ووکامرس فعال نیاز دارد.', 'site-revenue-calculator' ) . '</p></div>';
}
add_action( 'admin_notices', 'srevc_missing_woocommerce_notice' );

function srevc_bootstrap() {
	srevc_maybe_upgrade();
	Srevc_Settings::init();
	Srevc_Admin::init();
}
add_action( 'plugins_loaded', 'srevc_bootstrap' );
