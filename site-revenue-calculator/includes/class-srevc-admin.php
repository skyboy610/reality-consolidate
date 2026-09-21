<?php
defined( 'ABSPATH' ) || exit;

class Srevc_Admin {

	const PAGE_REPORT   = 'srevc-report';
	const PAGE_CLEANUP  = 'srevc-cleanup';
	const PAGE_SETTINGS = 'srevc-settings';

	public static function init() {
		add_action( 'admin_menu', array( __CLASS__, 'menu' ) );
		add_action( 'admin_enqueue_scripts', array( __CLASS__, 'assets' ) );
		add_action( 'admin_post_srevc_export', array( __CLASS__, 'export_csv' ) );
		add_action( 'admin_post_srevc_cleanup_delete', array( __CLASS__, 'handle_cleanup_delete' ) );
		add_action( 'admin_post_srevc_clear_log', array( __CLASS__, 'handle_clear_log' ) );
	}

	public static function menu() {
		if ( ! srevc_woocommerce_active() ) {
			return;
		}

		add_menu_page(
			__( 'محاسبه درآمد سایت', 'site-revenue-calculator' ),
			__( 'محاسبه درآمد', 'site-revenue-calculator' ),
			SREVC_CAPABILITY,
			self::PAGE_REPORT,
			array( __CLASS__, 'render_report' ),
			'dashicons-chart-area',
			56
		);

		add_submenu_page(
			self::PAGE_REPORT,
			__( 'گزارش درآمد', 'site-revenue-calculator' ),
			__( 'گزارش درآمد', 'site-revenue-calculator' ),
			SREVC_CAPABILITY,
			self::PAGE_REPORT,
			array( __CLASS__, 'render_report' )
		);

		add_submenu_page(
			self::PAGE_REPORT,
			__( 'پاک‌سازی سفارش تکراری', 'site-revenue-calculator' ),
			__( 'پاک‌سازی سفارش تکراری', 'site-revenue-calculator' ),
			SREVC_CAPABILITY,
			self::PAGE_CLEANUP,
			array( __CLASS__, 'render_cleanup' )
		);

		add_submenu_page(
			self::PAGE_REPORT,
			__( 'تنظیمات', 'site-revenue-calculator' ),
			__( 'تنظیمات', 'site-revenue-calculator' ),
			SREVC_CAPABILITY,
			self::PAGE_SETTINGS,
			array( 'Srevc_Settings', 'render' )
		);
	}

	public static function assets( $hook ) {
		$pages = array( self::PAGE_REPORT, self::PAGE_CLEANUP, self::PAGE_SETTINGS );
		$match = false;
		foreach ( $pages as $page ) {
			if ( false !== strpos( (string) $hook, $page ) ) {
				$match = true;
				break;
			}
		}
		if ( ! $match ) {
			return;
		}

		wp_enqueue_style( 'srevc-admin', SREVC_URL . 'assets/css/admin.css', array(), SREVC_VERSION );
		wp_enqueue_script( 'srevc-admin', SREVC_URL . 'assets/js/admin.js', array(), SREVC_VERSION, true );

		$today = Srevc_Jalali::today();
		wp_localize_script(
			'srevc-admin',
			'srevcData',
			array(
				'today'      => array(
					'jy' => $today[0],
					'jm' => $today[1],
					'jd' => $today[2],
				),
				'months'     => array_values( Srevc_Jalali::month_names() ),
				'weekdays'   => array( 'ش', 'ی', 'د', 'س', 'چ', 'پ', 'ج' ),
				'todayLabel' => __( 'امروز', 'site-revenue-calculator' ),
				'clearLabel' => __( 'پاک کردن', 'site-revenue-calculator' ),
			)
		);
	}

	public static function render_header( $title ) {
		?>
		<div class="srevc-banner">
			<div class="srevc-banner-logo">
				<pre class="srevc-ascii">
 ____  _____ _     _ _____ _   _ _   _ _____
|  _ \| ____| |   | | ____| \ | | | | | ____|
| |_) |  _| | |   | |  _| |  \| | | | |  _|
|  _ <| |___|  \_/  | |___| |\  | |_| | |___
|_| \_\_____|\_____/|_____|_| \_|\___/|_____|
				</pre>
			</div>
			<div class="srevc-banner-text">
				<h1><?php echo esc_html( $title ); ?></h1>
				<span class="srevc-banner-sub"><?php echo esc_html( sprintf( 'Site Revenue Calculator v%s', SREVC_VERSION ) ); ?></span>
			</div>
		</div>
		<?php
	}

	protected static function current_request() {
		$settings = srevc_get_settings();

		$preset = isset( $_GET['srevc_range'] ) ? sanitize_key( wp_unslash( $_GET['srevc_range'] ) ) : $settings['default_range'];
		if ( ! array_key_exists( $preset, Srevc_Range::presets() ) ) {
			$preset = $settings['default_range'];
		}

		$start = isset( $_GET['srevc_start'] ) ? sanitize_text_field( wp_unslash( $_GET['srevc_start'] ) ) : '';
		$end   = isset( $_GET['srevc_end'] ) ? sanitize_text_field( wp_unslash( $_GET['srevc_end'] ) ) : '';

		$statuses = array();
		if ( isset( $_GET['srevc_status'] ) && is_array( $_GET['srevc_status'] ) ) {
			$statuses = array_map( 'sanitize_text_field', wp_unslash( $_GET['srevc_status'] ) );
			$statuses = array_values( array_intersect( $statuses, array_keys( Srevc_Query::available_statuses() ) ) );
		}
		if ( empty( $statuses ) ) {
			$statuses = (array) $settings['statuses'];
		}

		return array(
			'preset'   => $preset,
			'start'    => $start,
			'end'      => $end,
			'statuses' => $statuses,
			'settings' => $settings,
		);
	}

	protected static function build_report( $request ) {
		$range = Srevc_Range::resolve( $request['preset'], $request['start'], $request['end'] );
		if ( is_wp_error( $range ) ) {
			return $range;
		}

		$settings = $request['settings'];

		return Srevc_Query::run(
			array(
				'start'                  => $range['start'],
				'end'                    => $range['end'],
				'statuses'               => $request['statuses'],
				'exclude_via'            => (array) $settings['exclude_via'],
				'exclude_zero'           => ! empty( $settings['exclude_zero'] ),
				'wallet_keywords'        => Srevc_Query::split_list( $settings['wallet_keywords'] ),
				'wallet_products'        => Srevc_Query::split_list( $settings['wallet_products'] ),
				'wallet_gateways'        => Srevc_Query::split_list( $settings['wallet_gateways'] ),
				'exclude_wallet_payment' => ! empty( $settings['exclude_wallet_payment'] ),
			)
		);
	}

	public static function group_badge( $group ) {
		$is_wallet = ( 'wallet' === $group['type'] );
		$is_manual = ! empty( $group['manual'] );

		if ( $is_wallet && $is_manual ) {
			return array(
				'label' => 'شارژ کیف پول (دستی مدیر)',
				'class' => 'srevc-badge-manual-wallet',
			);
		}
		if ( $is_wallet ) {
			return array(
				'label' => 'شارژ کیف پول',
				'class' => 'srevc-badge-wallet',
			);
		}
		if ( $is_manual ) {
			return array(
				'label' => 'سفارش دستی مدیر',
				'class' => 'srevc-badge-manual',
			);
		}
		return array(
			'label' => 'فروش / خدمات',
			'class' => 'srevc-badge-order',
		);
	}

	public static function render_report() {
		if ( ! srevc_user_can() ) {
			wp_die( esc_html__( 'شما دسترسی لازم برای مشاهده این صفحه را ندارید.', 'site-revenue-calculator' ) );
		}

		$request  = self::current_request();
		$settings = $request['settings'];
		$report   = self::build_report( $request );
		$presets  = Srevc_Range::presets();
		$statuses = Srevc_Query::available_statuses();

		$start_value = $request['start'];
		$end_value   = $request['end'];
		if ( ! is_wp_error( $report ) ) {
			$start_value = Srevc_Jalali::format_gregorian_string( $report['start'] );
			$end_value   = Srevc_Jalali::format_gregorian_string( $report['end'] );
		}
		?>
		<div class="wrap srevc-wrap" dir="rtl">
			<?php self::render_header( 'گزارش درآمد سایت' ); ?>

			<form method="get" class="srevc-card srevc-filters">
				<input type="hidden" name="page" value="<?php echo esc_attr( self::PAGE_REPORT ); ?>" />

				<div class="srevc-presets">
					<?php
					$index = 0;
					foreach ( $presets as $key => $label ) :
						$index++;
						?>
						<label class="srevc-chip srevc-chip-<?php echo esc_attr( $index ); ?> <?php echo ( $key === $request['preset'] ) ? 'is-active' : ''; ?>">
							<input type="radio" name="srevc_range" value="<?php echo esc_attr( $key ); ?>" <?php checked( $key, $request['preset'] ); ?> />
							<span><?php echo esc_html( $label ); ?></span>
						</label>
					<?php endforeach; ?>
				</div>

				<div class="srevc-filter-row">
					<div class="srevc-field">
						<label class="srevc-label-blue" for="srevc-start"><?php esc_html_e( 'از تاریخ', 'site-revenue-calculator' ); ?></label>
						<input type="text" id="srevc-start" name="srevc_start" value="<?php echo esc_attr( $start_value ); ?>" data-srevc-jalali="1" autocomplete="off" placeholder="۱۴۰۴/۰۱/۰۱" />
					</div>
					<div class="srevc-field">
						<label class="srevc-label-purple" for="srevc-end"><?php esc_html_e( 'تا تاریخ', 'site-revenue-calculator' ); ?></label>
						<input type="text" id="srevc-end" name="srevc_end" value="<?php echo esc_attr( $end_value ); ?>" data-srevc-jalali="1" autocomplete="off" placeholder="۱۴۰۴/۰۱/۳۱" />
					</div>
					<div class="srevc-field srevc-field-status">
						<span class="srevc-label-teal"><?php esc_html_e( 'وضعیت سفارش', 'site-revenue-calculator' ); ?></span>
						<div class="srevc-status-grid">
							<?php foreach ( $statuses as $key => $label ) : ?>
								<label class="srevc-status-chip">
									<input type="checkbox" name="srevc_status[]" value="<?php echo esc_attr( $key ); ?>" <?php checked( in_array( $key, (array) $request['statuses'], true ) ); ?> />
									<span><?php echo esc_html( $label ); ?></span>
								</label>
							<?php endforeach; ?>
						</div>
					</div>
					<div class="srevc-field srevc-field-actions">
						<button type="submit" class="srevc-btn srevc-btn-green"><?php esc_html_e( 'محاسبه کن', 'site-revenue-calculator' ); ?></button>
						<?php if ( ! is_wp_error( $report ) && $report['count'] > 0 ) : ?>
							<?php
							$export_url = wp_nonce_url(
								add_query_arg(
									array(
										'action'       => 'srevc_export',
										'srevc_range'  => $request['preset'],
										'srevc_start'  => $start_value,
										'srevc_end'    => $end_value,
										'srevc_status' => $request['statuses'],
									),
									admin_url( 'admin-post.php' )
								),
								'srevc_export'
							);
							?>
							<a class="srevc-btn srevc-btn-blue" href="<?php echo esc_url( $export_url ); ?>"><?php esc_html_e( 'خروجی CSV', 'site-revenue-calculator' ); ?></a>
						<?php endif; ?>
					</div>
				</div>
			</form>

			<?php if ( is_wp_error( $report ) ) : ?>
				<div class="srevc-msg srevc-msg-error"><?php echo esc_html( $report->get_error_message() ); ?></div>
				</div>
				<?php
				return;
			endif;
			?>

			<?php if ( ! empty( $report['db_error'] ) ) : ?>
				<div class="srevc-msg srevc-msg-error"><?php echo esc_html( sprintf( 'خطای پایگاه داده: %s', $report['db_error'] ) ); ?></div>
			<?php endif; ?>

			<div class="srevc-msg srevc-msg-warning">
				<?php echo esc_html( sprintf( 'بازه گزارش: %s', Srevc_Range::label( $report['start'], $report['end'] ) ) ); ?>
			</div>

			<div class="srevc-total-card">
				<span class="srevc-total-title"><?php esc_html_e( 'مبلغ کل درآمد', 'site-revenue-calculator' ); ?></span>
				<span class="srevc-total-value"><?php echo esc_html( Srevc_Format::money( $report['total'], $settings ) ); ?></span>
				<span class="srevc-total-words"><?php echo esc_html( Srevc_Format::money_words( $report['total'], $settings ) ); ?></span>
			</div>

			<div class="srevc-stats">
				<div class="srevc-stat srevc-stat-green">
					<span class="srevc-stat-label"><?php esc_html_e( 'تعداد کل تراکنش‌ها', 'site-revenue-calculator' ); ?></span>
					<span class="srevc-stat-value"><?php echo esc_html( Srevc_Format::count_label( $report['count'], $settings ) ); ?></span>
				</div>
				<div class="srevc-stat srevc-stat-blue">
					<span class="srevc-stat-label"><?php esc_html_e( 'میانگین هر تراکنش', 'site-revenue-calculator' ); ?></span>
					<span class="srevc-stat-value"><?php echo esc_html( Srevc_Format::money( $report['average'], $settings ) ); ?></span>
				</div>
				<div class="srevc-stat srevc-stat-teal">
					<span class="srevc-stat-label"><?php esc_html_e( 'فروش خدمات', 'site-revenue-calculator' ); ?></span>
					<span class="srevc-stat-value"><?php echo esc_html( Srevc_Format::money( $report['sales_total'], $settings ) ); ?></span>
					<span class="srevc-stat-sub"><?php echo esc_html( sprintf( '%s تراکنش', Srevc_Format::count_label( $report['sales_count'], $settings ) ) ); ?></span>
				</div>
				<div class="srevc-stat srevc-stat-purple">
					<span class="srevc-stat-label"><?php esc_html_e( 'شارژ کیف پول', 'site-revenue-calculator' ); ?></span>
					<span class="srevc-stat-value"><?php echo esc_html( Srevc_Format::money( $report['wallet_total'], $settings ) ); ?></span>
					<span class="srevc-stat-sub"><?php echo esc_html( sprintf( '%s تراکنش', Srevc_Format::count_label( $report['wallet_count'], $settings ) ) ); ?></span>
				</div>
				<div class="srevc-stat srevc-stat-orange">
					<span class="srevc-stat-label"><?php esc_html_e( 'سفارش دستی مدیر', 'site-revenue-calculator' ); ?></span>
					<span class="srevc-stat-value"><?php echo esc_html( Srevc_Format::money( $report['manual_total'], $settings ) ); ?></span>
					<span class="srevc-stat-sub"><?php echo esc_html( sprintf( '%s تراکنش', Srevc_Format::count_label( $report['manual_count'], $settings ) ) ); ?></span>
				</div>
				<div class="srevc-stat srevc-stat-indigo">
					<span class="srevc-stat-label"><?php esc_html_e( 'پرداخت با کیف پول', 'site-revenue-calculator' ); ?></span>
					<span class="srevc-stat-value"><?php echo esc_html( Srevc_Format::money( $report['gateway_wallet_total'], $settings ) ); ?></span>
					<span class="srevc-stat-sub"><?php echo esc_html( sprintf( '%s تراکنش', Srevc_Format::count_label( $report['gateway_wallet_count'], $settings ) ) ); ?></span>
				</div>
				<div class="srevc-stat srevc-stat-rose">
					<span class="srevc-stat-label"><?php esc_html_e( 'سفارش با کوپن', 'site-revenue-calculator' ); ?></span>
					<span class="srevc-stat-value"><?php echo esc_html( Srevc_Format::money( $report['coupon_total'], $settings ) ); ?></span>
					<span class="srevc-stat-sub"><?php echo esc_html( sprintf( '%s تراکنش | تخفیف %s', Srevc_Format::count_label( $report['coupon_count'], $settings ), Srevc_Format::money( $report['coupon_discount'], $settings ) ) ); ?></span>
				</div>
			</div>

			<div class="srevc-msg srevc-msg-success">
				<?php
				echo esc_html(
					sprintf(
						'حذف شده از محاسبه: %s تراکنش صفر ریال (تست رایگان) و %s سفارش با منبع کنارگذاشته‌شده.',
						Srevc_Format::count_label( $report['skipped_zero'], $settings ),
						Srevc_Format::count_label( $report['skipped_via'], $settings )
					)
				);
				?>
				<?php if ( $report['skipped_wallet_payment'] > 0 ) : ?>
					<?php echo esc_html( sprintf( ' همچنین %s پرداخت از کیف پول نادیده گرفته شد.', Srevc_Format::count_label( $report['skipped_wallet_payment'], $settings ) ) ); ?>
				<?php endif; ?>
			</div>

			<?php if ( empty( $report['groups'] ) ) : ?>
				<div class="srevc-msg srevc-msg-error"><?php esc_html_e( 'در این بازه هیچ تراکنش قابل محاسبه‌ای یافت نشد.', 'site-revenue-calculator' ); ?></div>
			<?php else : ?>
				<table class="srevc-table widefat">
					<thead>
						<tr>
							<th class="srevc-th-1"><?php esc_html_e( 'ردیف', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-2"><?php esc_html_e( 'نوع تراکنش', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-3"><?php esc_html_e( 'مبلغ هر تراکنش', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-4"><?php esc_html_e( 'تعداد', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-5"><?php esc_html_e( 'جمع مبلغ', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-6"><?php esc_html_e( 'سهم از درآمد', 'site-revenue-calculator' ); ?></th>
						</tr>
					</thead>
					<tbody>
						<?php $row_index = 0; ?>
						<?php foreach ( $report['groups'] as $group ) : ?>
							<?php
							$row_index++;
							$is_wallet = ( 'wallet' === $group['type'] );
							$share     = $report['total'] > 0 ? ( $group['sum'] / $report['total'] ) * 100 : 0;
							?>
							<tr>
								<td class="srevc-cell-index"><?php echo esc_html( Srevc_Format::count_label( $row_index, $settings ) ); ?></td>
								<td>
									<?php $badge = self::group_badge( $group ); ?>
									<span class="srevc-badge <?php echo esc_attr( $badge['class'] ); ?>">
										<?php echo esc_html( $badge['label'] ); ?>
									</span>
								</td>
								<td class="srevc-cell-amount">
									<strong><?php echo esc_html( Srevc_Format::money_words( $group['amount'], $settings ) ); ?></strong>
									<span class="srevc-cell-exact"><?php echo esc_html( Srevc_Format::money( $group['amount'], $settings ) ); ?></span>
								</td>
								<td class="srevc-cell-count"><?php echo esc_html( sprintf( '%s عدد', Srevc_Format::count_label( $group['count'], $settings ) ) ); ?></td>
								<td class="srevc-cell-sum"><?php echo esc_html( Srevc_Format::money( $group['sum'], $settings ) ); ?></td>
								<td class="srevc-cell-share">
									<span class="srevc-share-bar"><span class="srevc-share-fill" style="width:<?php echo esc_attr( min( 100, round( $share, 2 ) ) ); ?>%"></span></span>
									<span class="srevc-share-text"><?php echo esc_html( Srevc_Format::percent( $group['sum'], $report['total'], $settings ) ); ?></span>
								</td>
							</tr>
						<?php endforeach; ?>
					</tbody>
					<tfoot>
						<tr>
							<th colspan="3"><?php esc_html_e( 'جمع کل', 'site-revenue-calculator' ); ?></th>
							<th><?php echo esc_html( sprintf( '%s عدد', Srevc_Format::count_label( $report['count'], $settings ) ) ); ?></th>
							<th colspan="2"><?php echo esc_html( Srevc_Format::money( $report['total'], $settings ) ); ?></th>
						</tr>
					</tfoot>
				</table>
			<?php endif; ?>

			<?php if ( ! empty( $report['payments'] ) ) : ?>
				<h2 class="srevc-section-title srevc-title-blue"><?php esc_html_e( 'تفکیک بر اساس روش پرداخت', 'site-revenue-calculator' ); ?></h2>
				<table class="srevc-table widefat">
					<thead>
						<tr>
							<th class="srevc-th-3"><?php esc_html_e( 'روش پرداخت', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-4"><?php esc_html_e( 'تعداد', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-5"><?php esc_html_e( 'جمع مبلغ', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-6"><?php esc_html_e( 'سهم از درآمد', 'site-revenue-calculator' ); ?></th>
						</tr>
					</thead>
					<tbody>
						<?php foreach ( $report['payments'] as $payment ) : ?>
							<tr>
								<td class="srevc-cell-amount"><strong><?php echo esc_html( $payment['title'] ); ?></strong><span class="srevc-cell-exact"><?php echo esc_html( $payment['method'] ); ?></span></td>
								<td class="srevc-cell-count"><?php echo esc_html( sprintf( '%s عدد', Srevc_Format::count_label( $payment['count'], $settings ) ) ); ?></td>
								<td class="srevc-cell-sum"><?php echo esc_html( Srevc_Format::money( $payment['sum'], $settings ) ); ?></td>
								<td class="srevc-cell-share"><?php echo esc_html( Srevc_Format::percent( $payment['sum'], $report['total'], $settings ) ); ?></td>
							</tr>
						<?php endforeach; ?>
					</tbody>
				</table>
			<?php endif; ?>

			<?php if ( ! empty( $report['coupons'] ) ) : ?>
				<h2 class="srevc-section-title srevc-title-rose"><?php esc_html_e( 'تفکیک بر اساس کوپن تخفیف', 'site-revenue-calculator' ); ?></h2>
				<table class="srevc-table widefat">
					<thead>
						<tr>
							<th class="srevc-th-2"><?php esc_html_e( 'کد کوپن', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-4"><?php esc_html_e( 'تعداد استفاده', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-5"><?php esc_html_e( 'جمع مبلغ سفارش‌ها', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-6"><?php esc_html_e( 'جمع تخفیف', 'site-revenue-calculator' ); ?></th>
						</tr>
					</thead>
					<tbody>
						<?php foreach ( $report['coupons'] as $coupon ) : ?>
							<tr>
								<td><span class="srevc-badge srevc-badge-coupon"><?php echo esc_html( $coupon['code'] ); ?></span></td>
								<td class="srevc-cell-count"><?php echo esc_html( sprintf( '%s عدد', Srevc_Format::count_label( $coupon['count'], $settings ) ) ); ?></td>
								<td class="srevc-cell-sum"><?php echo esc_html( Srevc_Format::money( $coupon['sum'], $settings ) ); ?></td>
								<td class="srevc-cell-discount"><?php echo esc_html( Srevc_Format::money( $coupon['discount'], $settings ) ); ?></td>
							</tr>
						<?php endforeach; ?>
					</tbody>
				</table>
			<?php endif; ?>

			<p class="srevc-footnote">
				<?php
				echo esc_html(
					sprintf(
						'بررسی شده: %s سفارش | ساختار پایگاه داده: %s',
						Srevc_Format::count_label( $report['scanned'], $settings ),
						( 'hpos' === $report['storage'] ) ? 'HPOS' : 'Legacy'
					)
				);
				?>
			</p>
		</div>
		<?php
	}

	protected static function csv_line( $fields ) {
		$cells = array();
		foreach ( (array) $fields as $field ) {
			$cells[] = '"' . str_replace( '"', '""', (string) $field ) . '"';
		}
		return implode( ',', $cells ) . "\r\n";
	}

	public static function export_csv() {
		if ( ! srevc_user_can() ) {
			wp_die( esc_html__( 'شما دسترسی لازم برای دریافت خروجی را ندارید.', 'site-revenue-calculator' ) );
		}

		check_admin_referer( 'srevc_export' );

		$request  = self::current_request();
		$settings = $request['settings'];
		$report   = self::build_report( $request );

		if ( is_wp_error( $report ) ) {
			wp_die( esc_html( $report->get_error_message() ) );
		}

		$filename = 'revenue-' . $report['start'] . '-to-' . $report['end'] . '.csv';

		$body  = "\xEF\xBB\xBF";
		$body .= self::csv_line( array( 'بازه گزارش', Srevc_Range::label( $report['start'], $report['end'] ) ) );
		$body .= self::csv_line( array( 'واحد پول', $settings['currency_label'] ) );
		$body .= self::csv_line( array( '' ) );

		$body .= self::csv_line( array( 'شاخص', 'مبلغ', 'تعداد' ) );
		$body .= self::csv_line( array( 'مبلغ کل', Srevc_Format::raw_number( $report['total'], $settings ), $report['count'] ) );
		$body .= self::csv_line( array( 'میانگین هر تراکنش', Srevc_Format::raw_number( $report['average'], $settings ), '' ) );
		$body .= self::csv_line( array( 'فروش خدمات', Srevc_Format::raw_number( $report['sales_total'], $settings ), $report['sales_count'] ) );
		$body .= self::csv_line( array( 'شارژ کیف پول', Srevc_Format::raw_number( $report['wallet_total'], $settings ), $report['wallet_count'] ) );
		$body .= self::csv_line( array( 'سفارش دستی مدیر', Srevc_Format::raw_number( $report['manual_total'], $settings ), $report['manual_count'] ) );
		$body .= self::csv_line( array( 'پرداخت با کیف پول', Srevc_Format::raw_number( $report['gateway_wallet_total'], $settings ), $report['gateway_wallet_count'] ) );
		$body .= self::csv_line( array( 'سفارش با کوپن', Srevc_Format::raw_number( $report['coupon_total'], $settings ), $report['coupon_count'] ) );
		$body .= self::csv_line( array( 'جمع تخفیف کوپن', Srevc_Format::raw_number( $report['coupon_discount'], $settings ), '' ) );
		$body .= self::csv_line( array( 'تراکنش صفر حذف‌شده', '', $report['skipped_zero'] ) );
		$body .= self::csv_line( array( 'سفارش کنارگذاشته‌شده', '', $report['skipped_via'] ) );
		$body .= self::csv_line( array( '' ) );

		$body .= self::csv_line( array( 'تفکیک بر اساس مبلغ', '', '', '' ) );
		$body .= self::csv_line( array( 'نوع تراکنش', 'مبلغ هر تراکنش', 'تعداد', 'جمع مبلغ' ) );
		foreach ( $report['groups'] as $group ) {
			$badge = self::group_badge( $group );
			$body .= self::csv_line(
				array(
					$badge['label'],
					Srevc_Format::raw_number( $group['amount'], $settings ),
					$group['count'],
					Srevc_Format::raw_number( $group['sum'], $settings ),
				)
			);
		}

		if ( ! empty( $report['payments'] ) ) {
			$body .= self::csv_line( array( '' ) );
			$body .= self::csv_line( array( 'تفکیک بر اساس روش پرداخت', '', '', '' ) );
			$body .= self::csv_line( array( 'روش پرداخت', 'شناسه درگاه', 'تعداد', 'جمع مبلغ' ) );
			foreach ( $report['payments'] as $payment ) {
				$body .= self::csv_line(
					array(
						$payment['title'],
						$payment['method'],
						$payment['count'],
						Srevc_Format::raw_number( $payment['sum'], $settings ),
					)
				);
			}
		}

		if ( ! empty( $report['coupons'] ) ) {
			$body .= self::csv_line( array( '' ) );
			$body .= self::csv_line( array( 'تفکیک بر اساس کوپن', '', '', '' ) );
			$body .= self::csv_line( array( 'کد کوپن', 'تعداد استفاده', 'جمع مبلغ سفارش‌ها', 'جمع تخفیف' ) );
			foreach ( $report['coupons'] as $coupon ) {
				$body .= self::csv_line(
					array(
						$coupon['code'],
						$coupon['count'],
						Srevc_Format::raw_number( $coupon['sum'], $settings ),
						Srevc_Format::raw_number( $coupon['discount'], $settings ),
					)
				);
			}
		}

		nocache_headers();
		header( 'Content-Type: text/csv; charset=utf-8' );
		header( 'Content-Disposition: attachment; filename="' . $filename . '"' );
		header( 'Content-Length: ' . strlen( $body ) );

		echo $body;
		exit;
	}
	protected static function cleanup_request() {
		$settings = srevc_get_settings();
		$today    = Srevc_Range::today_gregorian();

		$start_input = isset( $_GET['srevc_start'] ) ? sanitize_text_field( wp_unslash( $_GET['srevc_start'] ) ) : '';
		$end_input   = isset( $_GET['srevc_end'] ) ? sanitize_text_field( wp_unslash( $_GET['srevc_end'] ) ) : '';

		$parsed_start = Srevc_Jalali::parse( $start_input );
		$parsed_end   = Srevc_Jalali::parse( $end_input );

		$start = $parsed_start ? Srevc_Jalali::to_gregorian_string( $parsed_start[0], $parsed_start[1], $parsed_start[2] ) : Srevc_Range::shift_days( $today, -29 );
		$end   = $parsed_end ? Srevc_Jalali::to_gregorian_string( $parsed_end[0], $parsed_end[1], $parsed_end[2] ) : $today;

		if ( strtotime( $start ) > strtotime( $end ) ) {
			$swap  = $start;
			$start = $end;
			$end   = $swap;
		}

		$window = isset( $_GET['srevc_window'] ) ? absint( wp_unslash( $_GET['srevc_window'] ) ) : (int) $settings['cleanup_window'];
		$window = min( 30, max( 0, $window ) );

		return array(
			'start'    => $start,
			'end'      => $end,
			'window'   => $window,
			'only'     => ! empty( $_GET['srevc_only'] ),
			'settings' => $settings,
			'invalid'  => ( ( '' !== $start_input && ! $parsed_start ) || ( '' !== $end_input && ! $parsed_end ) ),
		);
	}

	protected static function cleanup_url( $request, $extra = array() ) {
		$args = array(
			'page'         => self::PAGE_CLEANUP,
			'srevc_start'  => Srevc_Jalali::format_gregorian_string( $request['start'] ),
			'srevc_end'    => Srevc_Jalali::format_gregorian_string( $request['end'] ),
			'srevc_window' => $request['window'],
		);
		if ( ! empty( $request['only'] ) ) {
			$args['srevc_only'] = 1;
		}
		return add_query_arg( array_merge( $args, $extra ), admin_url( 'admin.php' ) );
	}

	protected static function render_order_row( $order, $is_admin_order ) {
		$settings = srevc_get_settings();
		?>
		<tr class="<?php echo $is_admin_order ? 'srevc-row-admin' : 'srevc-row-customer'; ?>">
			<td class="srevc-cell-check">
				<input type="checkbox" name="srevc_orders[]" value="<?php echo esc_attr( $order['id'] ); ?>" />
			</td>
			<td>
				<span class="srevc-badge <?php echo $is_admin_order ? 'srevc-badge-manual' : 'srevc-badge-order'; ?>">
					<?php echo esc_html( $is_admin_order ? 'ثبت مدیر' : 'سفارش مشتری' ); ?>
				</span>
			</td>
			<td class="srevc-cell-order">
				<a href="<?php echo esc_url( $order['edit_url'] ); ?>" target="_blank" rel="noopener">#<?php echo esc_html( $order['number'] ); ?></a>
				<span class="srevc-cell-exact"><?php echo esc_html( $order['items'] ); ?></span>
			</td>
			<td class="srevc-cell-customer"><?php echo esc_html( $order['customer'] ); ?></td>
			<td class="srevc-cell-date">
				<?php echo esc_html( $order['jalali'] ); ?>
				<span class="srevc-cell-exact"><?php echo esc_html( $order['time'] ); ?></span>
			</td>
			<td class="srevc-cell-sum">
				<?php echo esc_html( Srevc_Format::money( $order['total'], $settings ) ); ?>
				<?php if ( ! empty( $order['same_amount'] ) ) : ?>
					<span class="srevc-flag srevc-flag-same"><?php esc_html_e( 'مبلغ یکسان', 'site-revenue-calculator' ); ?></span>
				<?php endif; ?>
				<?php if ( isset( $order['day_gap'] ) ) : ?>
					<span class="srevc-flag srevc-flag-gap"><?php echo esc_html( sprintf( 'فاصله %s روز', Srevc_Format::count_label( $order['day_gap'], $settings ) ) ); ?></span>
				<?php endif; ?>
			</td>
			<td class="srevc-cell-status"><?php echo esc_html( $order['status_label'] ); ?></td>
			<td class="srevc-cell-pay">
				<?php echo esc_html( '' !== $order['payment'] ? $order['payment'] : 'نامشخص' ); ?>
				<?php if ( '' !== $order['coupons'] ) : ?>
					<span class="srevc-flag srevc-flag-coupon"><?php echo esc_html( $order['coupons'] ); ?></span>
				<?php endif; ?>
			</td>
		</tr>
		<?php
	}

	public static function render_cleanup() {
		if ( ! srevc_user_can() ) {
			wp_die( esc_html__( 'شما دسترسی لازم برای مشاهده این صفحه را ندارید.', 'site-revenue-calculator' ) );
		}

		$request  = self::cleanup_request();
		$settings = $request['settings'];
		$result   = Srevc_Cleanup::find_groups( $request['start'], $request['end'], $request['window'], $request['only'] );
		$groups   = $result['groups'];
		?>
		<div class="wrap srevc-wrap" dir="rtl">
			<?php self::render_header( 'پاک‌سازی سفارش‌های تکراری' ); ?>

			<?php if ( isset( $_GET['srevc_deleted'] ) ) : ?>
				<div class="srevc-msg srevc-msg-success">
					<?php echo esc_html( sprintf( '%s سفارش حذف شد.', Srevc_Format::count_label( absint( wp_unslash( $_GET['srevc_deleted'] ) ), $settings ) ) ); ?>
					<?php if ( ! empty( $_GET['srevc_failed'] ) ) : ?>
						<?php echo esc_html( sprintf( ' | %s مورد ناموفق بود.', Srevc_Format::count_label( absint( wp_unslash( $_GET['srevc_failed'] ) ), $settings ) ) ); ?>
					<?php endif; ?>
				</div>
			<?php endif; ?>

			<?php if ( isset( $_GET['srevc_error'] ) ) : ?>
				<?php
				$error_key = sanitize_key( wp_unslash( $_GET['srevc_error'] ) );
				$errors    = array(
					'none'    => 'هیچ سفارشی انتخاب نشده بود.',
					'confirm' => 'برای حذف دائمی باید تیک تأیید را بزنید.',
				);
				$message   = isset( $errors[ $error_key ] ) ? $errors[ $error_key ] : 'درخواست انجام نشد.';
				?>
				<div class="srevc-msg srevc-msg-error"><?php echo esc_html( $message ); ?></div>
			<?php endif; ?>

			<?php if ( $request['invalid'] ) : ?>
				<div class="srevc-msg srevc-msg-error"><?php esc_html_e( 'تاریخ واردشده معتبر نبود و بازه پیش‌فرض نمایش داده شد.', 'site-revenue-calculator' ); ?></div>
			<?php endif; ?>

			<form method="get" class="srevc-card srevc-filters">
				<input type="hidden" name="page" value="<?php echo esc_attr( self::PAGE_CLEANUP ); ?>" />
				<div class="srevc-filter-row">
					<div class="srevc-field">
						<label class="srevc-label-blue" for="srevc-cleanup-start"><?php esc_html_e( 'از تاریخ', 'site-revenue-calculator' ); ?></label>
						<input type="text" id="srevc-cleanup-start" name="srevc_start" value="<?php echo esc_attr( Srevc_Jalali::format_gregorian_string( $request['start'] ) ); ?>" data-srevc-jalali="1" autocomplete="off" />
					</div>
					<div class="srevc-field">
						<label class="srevc-label-purple" for="srevc-cleanup-end"><?php esc_html_e( 'تا تاریخ', 'site-revenue-calculator' ); ?></label>
						<input type="text" id="srevc-cleanup-end" name="srevc_end" value="<?php echo esc_attr( Srevc_Jalali::format_gregorian_string( $request['end'] ) ); ?>" data-srevc-jalali="1" autocomplete="off" />
					</div>
					<div class="srevc-field">
						<label class="srevc-label-orange" for="srevc-cleanup-window"><?php esc_html_e( 'بازه تطبیق (روز)', 'site-revenue-calculator' ); ?></label>
						<input type="number" id="srevc-cleanup-window" name="srevc_window" min="0" max="30" value="<?php echo esc_attr( $request['window'] ); ?>" />
					</div>
					<div class="srevc-field">
						<span class="srevc-label-teal"><?php esc_html_e( 'فیلتر', 'site-revenue-calculator' ); ?></span>
						<label class="srevc-status-chip">
							<input type="checkbox" name="srevc_only" value="1" <?php checked( $request['only'] ); ?> />
							<span><?php esc_html_e( 'فقط سفارش‌هایی که مشابه دارند', 'site-revenue-calculator' ); ?></span>
						</label>
					</div>
					<div class="srevc-field srevc-field-actions">
						<button type="submit" class="srevc-btn srevc-btn-green"><?php esc_html_e( 'جستجو', 'site-revenue-calculator' ); ?></button>
					</div>
				</div>
			</form>

			<div class="srevc-msg srevc-msg-warning">
				<?php
				echo esc_html(
					sprintf(
						'بازه: %s | سفارش‌های دستی یافت‌شده: %s | سفارش‌های بررسی‌شده: %s',
						Srevc_Range::label( $request['start'], $request['end'] ),
						Srevc_Format::count_label( count( $groups ), $settings ),
						Srevc_Format::count_label( $result['scanned'], $settings )
					)
				);
				?>
			</div>

			<?php if ( $result['capped'] ) : ?>
				<div class="srevc-msg srevc-msg-error"><?php esc_html_e( 'تعداد سفارش‌های این بازه از حد مجاز بیشتر است و همه بررسی نشدند. بازه را کوچک‌تر کنید.', 'site-revenue-calculator' ); ?></div>
			<?php endif; ?>

			<?php if ( empty( $groups ) ) : ?>
				<div class="srevc-msg srevc-msg-success"><?php esc_html_e( 'در این بازه هیچ سفارش دستی مدیر پیدا نشد.', 'site-revenue-calculator' ); ?></div>
			<?php else : ?>
				<form method="post" action="<?php echo esc_url( admin_url( 'admin-post.php' ) ); ?>" class="srevc-cleanup-form">
					<input type="hidden" name="action" value="srevc_cleanup_delete" />
					<input type="hidden" name="srevc_start" value="<?php echo esc_attr( Srevc_Jalali::format_gregorian_string( $request['start'] ) ); ?>" />
					<input type="hidden" name="srevc_end" value="<?php echo esc_attr( Srevc_Jalali::format_gregorian_string( $request['end'] ) ); ?>" />
					<input type="hidden" name="srevc_window" value="<?php echo esc_attr( $request['window'] ); ?>" />
					<input type="hidden" name="srevc_only" value="<?php echo esc_attr( $request['only'] ? 1 : 0 ); ?>" />
					<?php wp_nonce_field( 'srevc_cleanup_delete' ); ?>

					<?php foreach ( $groups as $group ) : ?>
						<div class="srevc-group">
							<div class="srevc-group-head">
								<span class="srevc-group-title"><?php echo esc_html( sprintf( 'مشتری: %s', $group['admin']['customer'] ) ); ?></span>
								<label class="srevc-group-select">
									<input type="checkbox" data-srevc-toggle-group="1" />
									<span><?php esc_html_e( 'انتخاب همه این گروه', 'site-revenue-calculator' ); ?></span>
								</label>
								<span class="srevc-group-meta">
									<?php
									echo esc_html(
										sprintf(
											'%s سفارش مشابه در بازه %s روز',
											Srevc_Format::count_label( count( $group['matches'] ), $settings ),
											Srevc_Format::count_label( $request['window'], $settings )
										)
									);
									?>
								</span>
							</div>
							<table class="srevc-table srevc-table-compact widefat">
								<tbody>
									<?php self::render_order_row( $group['admin'], true ); ?>
									<?php foreach ( $group['matches'] as $match ) : ?>
										<?php self::render_order_row( $match, false ); ?>
									<?php endforeach; ?>
									<?php if ( empty( $group['matches'] ) ) : ?>
										<tr>
											<td colspan="8" class="srevc-empty-match"><?php esc_html_e( 'سفارش مشابهی برای این مشتری در این بازه پیدا نشد.', 'site-revenue-calculator' ); ?></td>
										</tr>
									<?php endif; ?>
								</tbody>
							</table>
						</div>
					<?php endforeach; ?>

					<div class="srevc-card srevc-actions-bar">
						<label class="srevc-status-chip">
							<input type="radio" name="srevc_mode" value="trash" checked="checked" />
							<span><?php esc_html_e( 'انتقال به زباله‌دان (قابل بازگشت)', 'site-revenue-calculator' ); ?></span>
						</label>
						<label class="srevc-status-chip srevc-chip-danger">
							<input type="radio" name="srevc_mode" value="permanent" />
							<span><?php esc_html_e( 'حذف دائمی (غیرقابل بازگشت)', 'site-revenue-calculator' ); ?></span>
						</label>
						<label class="srevc-status-chip srevc-chip-danger">
							<input type="checkbox" name="srevc_confirm" value="1" />
							<span><?php esc_html_e( 'تأیید می‌کنم حذف دائمی برگشت‌پذیر نیست', 'site-revenue-calculator' ); ?></span>
						</label>
						<button type="submit" class="srevc-btn srevc-btn-red" data-srevc-confirm="<?php esc_attr_e( 'سفارش‌های انتخاب‌شده حذف شوند؟', 'site-revenue-calculator' ); ?>">
							<?php esc_html_e( 'حذف سفارش‌های انتخاب‌شده', 'site-revenue-calculator' ); ?>
						</button>
					</div>
				</form>
			<?php endif; ?>

			<?php $log = Srevc_Cleanup::get_log( 30 ); ?>
			<h2 class="srevc-section-title srevc-title-purple"><?php esc_html_e( 'گزارش حذف‌ها', 'site-revenue-calculator' ); ?></h2>
			<?php if ( empty( $log ) ) : ?>
				<div class="srevc-msg srevc-msg-warning"><?php esc_html_e( 'تا این لحظه هیچ سفارشی با این ابزار حذف نشده است.', 'site-revenue-calculator' ); ?></div>
			<?php else : ?>
				<table class="srevc-table widefat">
					<thead>
						<tr>
							<th class="srevc-th-1"><?php esc_html_e( 'زمان', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-2"><?php esc_html_e( 'سفارش', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-3"><?php esc_html_e( 'مشتری', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-5"><?php esc_html_e( 'مبلغ', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-4"><?php esc_html_e( 'نوع حذف', 'site-revenue-calculator' ); ?></th>
							<th class="srevc-th-6"><?php esc_html_e( 'کاربر', 'site-revenue-calculator' ); ?></th>
						</tr>
					</thead>
					<tbody>
						<?php foreach ( $log as $entry ) : ?>
							<tr class="<?php echo ( 'success' === $entry['status'] ) ? 'srevc-log-ok' : 'srevc-log-err'; ?>">
								<td><?php echo esc_html( Srevc_Jalali::format_gregorian_string( substr( $entry['time'], 0, 10 ), true ) . ' ' . substr( $entry['time'], 11, 5 ) ); ?></td>
								<td>#<?php echo esc_html( $entry['order'] ); ?></td>
								<td><?php echo esc_html( $entry['customer'] ); ?></td>
								<td class="srevc-cell-sum"><?php echo esc_html( Srevc_Format::money( $entry['total'], $settings ) ); ?></td>
								<td>
									<span class="srevc-badge <?php echo ( 'permanent' === $entry['mode'] ) ? 'srevc-badge-danger' : 'srevc-badge-order'; ?>">
										<?php echo esc_html( ( 'permanent' === $entry['mode'] ) ? 'حذف دائمی' : 'زباله‌دان' ); ?>
									</span>
								</td>
								<td><?php echo esc_html( $entry['user'] ); ?></td>
							</tr>
						<?php endforeach; ?>
					</tbody>
				</table>
				<p>
					<a class="srevc-btn srevc-btn-yellow" href="<?php echo esc_url( wp_nonce_url( add_query_arg( array( 'action' => 'srevc_clear_log' ), admin_url( 'admin-post.php' ) ), 'srevc_clear_log' ) ); ?>" data-srevc-confirm="<?php esc_attr_e( 'گزارش حذف‌ها پاک شود؟', 'site-revenue-calculator' ); ?>">
						<?php esc_html_e( 'پاک کردن گزارش', 'site-revenue-calculator' ); ?>
					</a>
				</p>
			<?php endif; ?>
		</div>
		<?php
	}

	public static function handle_cleanup_delete() {
		if ( ! srevc_user_can() ) {
			wp_die( esc_html__( 'شما دسترسی لازم برای حذف سفارش را ندارید.', 'site-revenue-calculator' ) );
		}

		check_admin_referer( 'srevc_cleanup_delete' );

		$request = array(
			'start'  => '',
			'end'    => '',
			'window' => 3,
			'only'   => false,
		);

		$start_input = isset( $_POST['srevc_start'] ) ? sanitize_text_field( wp_unslash( $_POST['srevc_start'] ) ) : '';
		$end_input   = isset( $_POST['srevc_end'] ) ? sanitize_text_field( wp_unslash( $_POST['srevc_end'] ) ) : '';
		$parsed_start = Srevc_Jalali::parse( $start_input );
		$parsed_end   = Srevc_Jalali::parse( $end_input );
		$today        = Srevc_Range::today_gregorian();

		$request['start']  = $parsed_start ? Srevc_Jalali::to_gregorian_string( $parsed_start[0], $parsed_start[1], $parsed_start[2] ) : Srevc_Range::shift_days( $today, -29 );
		$request['end']    = $parsed_end ? Srevc_Jalali::to_gregorian_string( $parsed_end[0], $parsed_end[1], $parsed_end[2] ) : $today;
		$request['window'] = isset( $_POST['srevc_window'] ) ? min( 30, max( 0, absint( wp_unslash( $_POST['srevc_window'] ) ) ) ) : 3;
		$request['only']   = ! empty( $_POST['srevc_only'] );

		$ids  = isset( $_POST['srevc_orders'] ) ? array_map( 'absint', (array) wp_unslash( $_POST['srevc_orders'] ) ) : array();
		$ids  = array_values( array_filter( $ids ) );
		$mode = isset( $_POST['srevc_mode'] ) ? sanitize_key( wp_unslash( $_POST['srevc_mode'] ) ) : 'trash';

		if ( empty( $ids ) ) {
			wp_safe_redirect( self::cleanup_url( $request, array( 'srevc_error' => 'none' ) ) );
			exit;
		}

		$permanent = ( 'permanent' === $mode );
		if ( $permanent && empty( $_POST['srevc_confirm'] ) ) {
			wp_safe_redirect( self::cleanup_url( $request, array( 'srevc_error' => 'confirm' ) ) );
			exit;
		}

		$result = Srevc_Cleanup::delete_orders( $ids, $permanent );

		wp_safe_redirect(
			self::cleanup_url(
				$request,
				array(
					'srevc_deleted' => $result['deleted'],
					'srevc_failed'  => $result['failed'],
				)
			)
		);
		exit;
	}

	public static function handle_clear_log() {
		if ( ! srevc_user_can() ) {
			wp_die( esc_html__( 'شما دسترسی لازم برای این کار را ندارید.', 'site-revenue-calculator' ) );
		}

		check_admin_referer( 'srevc_clear_log' );
		Srevc_Cleanup::clear_log();

		wp_safe_redirect( add_query_arg( array( 'page' => self::PAGE_CLEANUP ), admin_url( 'admin.php' ) ) );
		exit;
	}

}
