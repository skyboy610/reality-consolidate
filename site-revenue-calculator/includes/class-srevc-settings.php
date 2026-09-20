<?php
defined( 'ABSPATH' ) || exit;

class Srevc_Settings {

	public static function init() {
		add_action( 'admin_init', array( __CLASS__, 'register' ) );
	}

	public static function register() {
		register_setting(
			'srevc_settings_group',
			SREVC_OPTION,
			array(
				'type'              => 'array',
				'sanitize_callback' => array( __CLASS__, 'sanitize' ),
				'default'           => srevc_default_settings(),
			)
		);
	}

	public static function sanitize( $input ) {
		$defaults = srevc_default_settings();
		$output   = srevc_get_settings();

		if ( ! is_array( $input ) ) {
			return $output;
		}

		$available = array_keys( Srevc_Query::available_statuses() );
		$statuses  = isset( $input['statuses'] ) ? (array) $input['statuses'] : array();
		$statuses  = array_values( array_intersect( array_map( 'sanitize_text_field', $statuses ), $available ) );
		$output['statuses'] = empty( $statuses ) ? $defaults['statuses'] : $statuses;

		$exclude_via = isset( $input['exclude_via'] ) ? sanitize_text_field( $input['exclude_via'] ) : '';
		$exclude_via = Srevc_Query::split_list( $exclude_via );
		$output['exclude_via'] = array_map( 'sanitize_key', $exclude_via );

		$output['exclude_zero']           = empty( $input['exclude_zero'] ) ? 0 : 1;
		$output['exclude_wallet_payment'] = empty( $input['exclude_wallet_payment'] ) ? 0 : 1;
		$output['divide_by_ten']          = empty( $input['divide_by_ten'] ) ? 0 : 1;
		$output['persian_digits']         = empty( $input['persian_digits'] ) ? 0 : 1;

		$output['wallet_keywords'] = isset( $input['wallet_keywords'] ) ? sanitize_text_field( $input['wallet_keywords'] ) : '';
		$output['wallet_gateways'] = isset( $input['wallet_gateways'] ) ? sanitize_text_field( $input['wallet_gateways'] ) : '';

		$products = isset( $input['wallet_products'] ) ? sanitize_text_field( $input['wallet_products'] ) : '';
		$products = array_map( 'absint', Srevc_Query::split_list( $products ) );
		$products = array_values( array_filter( $products ) );
		$output['wallet_products'] = implode( ',', $products );

		$currency = isset( $input['currency_label'] ) ? sanitize_text_field( $input['currency_label'] ) : $defaults['currency_label'];
		$output['currency_label'] = '' === $currency ? $defaults['currency_label'] : $currency;

		$presets = array_keys( Srevc_Range::presets() );
		$range   = isset( $input['default_range'] ) ? sanitize_key( $input['default_range'] ) : $defaults['default_range'];
		$output['default_range'] = in_array( $range, $presets, true ) ? $range : $defaults['default_range'];

		return $output;
	}

	public static function render() {
		if ( ! srevc_user_can() ) {
			wp_die( esc_html__( 'شما دسترسی لازم برای مشاهده این صفحه را ندارید.', 'site-revenue-calculator' ) );
		}

		$settings = srevc_get_settings();
		$statuses = Srevc_Query::available_statuses();
		?>
		<div class="wrap srevc-wrap" dir="rtl">
			<?php Srevc_Admin::render_header( 'تنظیمات محاسبه درآمد' ); ?>

			<form method="post" action="options.php" class="srevc-card srevc-card-settings">
				<?php settings_fields( 'srevc_settings_group' ); ?>

				<table class="form-table srevc-form-table" role="presentation">
					<tr>
						<th scope="row"><span class="srevc-label-blue"><?php esc_html_e( 'وضعیت‌های قابل محاسبه', 'site-revenue-calculator' ); ?></span></th>
						<td>
							<div class="srevc-status-grid">
								<?php foreach ( $statuses as $key => $label ) : ?>
									<label class="srevc-status-chip">
										<input type="checkbox" name="<?php echo esc_attr( SREVC_OPTION ); ?>[statuses][]" value="<?php echo esc_attr( $key ); ?>" <?php checked( in_array( $key, (array) $settings['statuses'], true ) ); ?> />
										<span><?php echo esc_html( $label ); ?></span>
									</label>
								<?php endforeach; ?>
							</div>
							<p class="description srevc-hint"><?php esc_html_e( 'تنها سفارش‌هایی با این وضعیت‌ها در محاسبه درآمد لحاظ می‌شوند.', 'site-revenue-calculator' ); ?></p>
						</td>
					</tr>
					<tr>
						<th scope="row"><span class="srevc-label-purple"><?php esc_html_e( 'حذف تراکنش‌های دستی', 'site-revenue-calculator' ); ?></span></th>
						<td>
							<input type="text" class="regular-text ltr" dir="ltr" name="<?php echo esc_attr( SREVC_OPTION ); ?>[exclude_via]" value="<?php echo esc_attr( implode( ', ', (array) $settings['exclude_via'] ) ); ?>" />
							<p class="description srevc-hint"><?php esc_html_e( 'مقدار created_via سفارش‌هایی که نباید محاسبه شوند. مقدار admin یعنی سفارش‌هایی که مدیر دستی در پیشخوان ثبت کرده است.', 'site-revenue-calculator' ); ?></p>
						</td>
					</tr>
					<tr>
						<th scope="row"><span class="srevc-label-orange"><?php esc_html_e( 'حذف تراکنش صفر', 'site-revenue-calculator' ); ?></span></th>
						<td>
							<label class="srevc-switch">
								<input type="checkbox" name="<?php echo esc_attr( SREVC_OPTION ); ?>[exclude_zero]" value="1" <?php checked( ! empty( $settings['exclude_zero'] ) ); ?> />
								<span><?php esc_html_e( 'سفارش‌های صفر ریال (تست رایگان) محاسبه نشوند', 'site-revenue-calculator' ); ?></span>
							</label>
						</td>
					</tr>
					<tr>
						<th scope="row"><span class="srevc-label-teal"><?php esc_html_e( 'کلیدواژه شارژ کیف پول', 'site-revenue-calculator' ); ?></span></th>
						<td>
							<input type="text" class="regular-text" name="<?php echo esc_attr( SREVC_OPTION ); ?>[wallet_keywords]" value="<?php echo esc_attr( $settings['wallet_keywords'] ); ?>" />
							<p class="description srevc-hint"><?php esc_html_e( 'اگر نام محصول سفارش شامل یکی از این عبارت‌ها باشد، آن تراکنش به عنوان شارژ کیف پول تفکیک می‌شود. با کاما جدا کنید.', 'site-revenue-calculator' ); ?></p>
						</td>
					</tr>
					<tr>
						<th scope="row"><span class="srevc-label-teal"><?php esc_html_e( 'شناسه محصول کیف پول', 'site-revenue-calculator' ); ?></span></th>
						<td>
							<input type="text" class="regular-text ltr" dir="ltr" name="<?php echo esc_attr( SREVC_OPTION ); ?>[wallet_products]" value="<?php echo esc_attr( $settings['wallet_products'] ); ?>" />
							<p class="description srevc-hint"><?php esc_html_e( 'شناسه عددی محصول یا محصولات شارژ کیف پول، جدا شده با کاما. اختیاری است.', 'site-revenue-calculator' ); ?></p>
						</td>
					</tr>
					<tr>
						<th scope="row"><span class="srevc-label-pink"><?php esc_html_e( 'درگاه کیف پول', 'site-revenue-calculator' ); ?></span></th>
						<td>
							<input type="text" class="regular-text ltr" dir="ltr" name="<?php echo esc_attr( SREVC_OPTION ); ?>[wallet_gateways]" value="<?php echo esc_attr( $settings['wallet_gateways'] ); ?>" />
							<label class="srevc-switch">
								<input type="checkbox" name="<?php echo esc_attr( SREVC_OPTION ); ?>[exclude_wallet_payment]" value="1" <?php checked( ! empty( $settings['exclude_wallet_payment'] ) ); ?> />
								<span><?php esc_html_e( 'سفارش‌هایی که با موجودی کیف پول پرداخت شده‌اند محاسبه نشوند (جلوگیری از محاسبه دوباره)', 'site-revenue-calculator' ); ?></span>
							</label>
						</td>
					</tr>
					<tr>
						<th scope="row"><span class="srevc-label-green"><?php esc_html_e( 'نمایش مبالغ', 'site-revenue-calculator' ); ?></span></th>
						<td>
							<label class="srevc-switch">
								<input type="checkbox" name="<?php echo esc_attr( SREVC_OPTION ); ?>[divide_by_ten]" value="1" <?php checked( ! empty( $settings['divide_by_ten'] ) ); ?> />
								<span><?php esc_html_e( 'مبالغ ووکامرس ریال است، برای نمایش بر ۱۰ تقسیم شود', 'site-revenue-calculator' ); ?></span>
							</label>
							<br />
							<label class="srevc-switch">
								<input type="checkbox" name="<?php echo esc_attr( SREVC_OPTION ); ?>[persian_digits]" value="1" <?php checked( ! empty( $settings['persian_digits'] ) ); ?> />
								<span><?php esc_html_e( 'نمایش اعداد با ارقام فارسی', 'site-revenue-calculator' ); ?></span>
							</label>
							<br />
							<input type="text" class="small-text" name="<?php echo esc_attr( SREVC_OPTION ); ?>[currency_label]" value="<?php echo esc_attr( $settings['currency_label'] ); ?>" />
							<span class="srevc-hint"><?php esc_html_e( 'واحد پول نمایشی', 'site-revenue-calculator' ); ?></span>
						</td>
					</tr>
					<tr>
						<th scope="row"><span class="srevc-label-blue"><?php esc_html_e( 'بازه پیش‌فرض گزارش', 'site-revenue-calculator' ); ?></span></th>
						<td>
							<select name="<?php echo esc_attr( SREVC_OPTION ); ?>[default_range]">
								<?php foreach ( Srevc_Range::presets() as $key => $label ) : ?>
									<option value="<?php echo esc_attr( $key ); ?>" <?php selected( $settings['default_range'], $key ); ?>><?php echo esc_html( $label ); ?></option>
								<?php endforeach; ?>
							</select>
						</td>
					</tr>
				</table>

				<?php submit_button( __( 'ذخیره تنظیمات', 'site-revenue-calculator' ), 'primary srevc-submit' ); ?>
			</form>
		</div>
		<?php
	}
}
